// web-metrics-exporter reads the gikview web demand counter from DynamoDB
// (written by the backend handler Lambda on each WebSocket $connect) and
// re-exposes it as a Prometheus counter for the edge monitoring stack.
//
// AWS access uses IAM Roles Anywhere temporary credentials via aws_signing_helper
// (credential_process) — same trust material as edge-gateway, read-only role.
// DynamoDB is polled on a fixed interval and cached so the Prometheus scrape
// frequency is decoupled from RCU cost.
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials/processcreds"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	ddtypes "github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// exporter-internal health (scrape success/failure of the DynamoDB poll).
var (
	scrapeErrors = promauto.NewCounter(prometheus.CounterOpts{
		Name: "web_metrics_scrape_errors_total",
		Help: "DynamoDB poll failures (exporter could not read the counter).",
	})
	lastSuccess = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "web_metrics_last_scrape_success_timestamp_seconds",
		Help: "Unix time of the last successful DynamoDB poll.",
	})
)

// connectCounter is a custom collector mirroring the monotonic DynamoDB counter
// value as a Prometheus counter. The value lives in DynamoDB (ADD-only), so it
// survives exporter restarts without a spurious rate() reset. 0-initialised so
// the series is exposed before the first poll (No-data prevention).
type connectCounter struct {
	desc  *prometheus.Desc
	stage string
	mu    sync.RWMutex
	value float64
}

func newConnectCounter(stage string) *connectCounter {
	return &connectCounter{
		desc: prometheus.NewDesc(
			"web_connect_total",
			"WebSocket $connect attempts (user demand), mirrored from DynamoDB.",
			nil, prometheus.Labels{"stage": stage},
		),
		stage: stage,
	}
}

func (c *connectCounter) Describe(ch chan<- *prometheus.Desc) { ch <- c.desc }

func (c *connectCounter) Collect(ch chan<- prometheus.Metric) {
	c.mu.RLock()
	v := c.value
	c.mu.RUnlock()
	ch <- prometheus.MustNewConstMetric(c.desc, prometheus.CounterValue, v)
}

func (c *connectCounter) set(v float64) {
	c.mu.Lock()
	c.value = v
	c.mu.Unlock()
}

type Config struct {
	Region         string
	TrustAnchorARN string
	ProfileARN     string
	RoleARN        string
	SigningHelper  string
	TLSCertFile    string
	TLSKeyFile     string
	Table          string
	Stage          string
	MetricKey      string
	PollInterval   time.Duration
	MetricsAddr    string
}

func mustEnv(k string) string {
	v := os.Getenv(k)
	if v == "" {
		log.Fatalf("FATAL: env %s required", k)
	}
	return v
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func loadConfig() *Config {
	pollSec, err := strconv.Atoi(envOr("POLL_INTERVAL_SECONDS", "60"))
	if err != nil || pollSec <= 0 {
		log.Fatalf("FATAL: POLL_INTERVAL_SECONDS invalid: %q", os.Getenv("POLL_INTERVAL_SECONDS"))
	}
	return &Config{
		Region:         mustEnv("AWS_DEFAULT_REGION"),
		TrustAnchorARN: mustEnv("TRUST_ANCHOR_ARN"),
		ProfileARN:     mustEnv("PROFILE_ARN"),
		RoleARN:        mustEnv("ROLE_ARN"),
		SigningHelper:  envOr("AWS_SIGNING_HELPER", "/usr/local/bin/aws_signing_helper"),
		TLSCertFile:    envOr("TLS_CERT_FILE", "/tls/tls.crt"),
		TLSKeyFile:     envOr("TLS_KEY_FILE", "/tls/tls.key"),
		Table:          mustEnv("METRICS_TABLE"),
		Stage:          mustEnv("METRIC_STAGE"),
		MetricKey:      envOr("METRIC_KEY", "connect"),
		PollInterval:   time.Duration(pollSec) * time.Second,
		MetricsAddr:    envOr("METRICS_ADDR", ":9102"),
	}
}

// buildAWSConfig wires the SDK to obtain credentials via aws_signing_helper
// (IAM Roles Anywhere) using credential_process, with the web-visibility mTLS
// cert as the trust material.
func buildAWSConfig(ctx context.Context, cfg *Config) (aws.Config, error) {
	cmd := fmt.Sprintf(
		"%s credential-process --certificate %s --private-key %s --trust-anchor-arn %s --profile-arn %s --role-arn %s --region %s",
		cfg.SigningHelper,
		cfg.TLSCertFile, cfg.TLSKeyFile,
		cfg.TrustAnchorARN, cfg.ProfileARN, cfg.RoleARN, cfg.Region,
	)
	prov := processcreds.NewProvider(cmd)
	return awsconfig.LoadDefaultConfig(ctx,
		awsconfig.WithRegion(cfg.Region),
		awsconfig.WithCredentialsProvider(aws.NewCredentialsCache(prov)),
	)
}

// poll reads the counter item and updates the cached value. A missing item
// (no $connect yet) is a successful read of value 0, not an error.
func poll(ctx context.Context, ddb *dynamodb.Client, cfg *Config, cc *connectCounter) {
	getCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	out, err := ddb.GetItem(getCtx, &dynamodb.GetItemInput{
		TableName: aws.String(cfg.Table),
		Key: map[string]ddtypes.AttributeValue{
			"metric": &ddtypes.AttributeValueMemberS{Value: cfg.MetricKey},
		},
		ConsistentRead: aws.Bool(false), // eventually-consistent = half RCU
	})
	if err != nil {
		scrapeErrors.Inc()
		log.Printf("WARN: GetItem %s[%s]: %v", cfg.Table, cfg.MetricKey, err)
		return
	}
	v := 0.0
	if av, ok := out.Item["n"]; ok {
		n, isN := av.(*ddtypes.AttributeValueMemberN)
		if !isN {
			scrapeErrors.Inc()
			log.Printf("WARN: attribute n is not a Number on %s[%s]", cfg.Table, cfg.MetricKey)
			return
		}
		f, perr := strconv.ParseFloat(n.Value, 64)
		if perr != nil {
			scrapeErrors.Inc()
			log.Printf("WARN: parse n=%q: %v", n.Value, perr)
			return
		}
		v = f
	}
	cc.set(v)
	lastSuccess.SetToCurrentTime()
}

func serveMetrics(addr string) {
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())
	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	log.Printf("metrics server listening on %s/metrics", addr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Printf("WARN: metrics server stopped: %v", err)
	}
}

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	cfg := loadConfig()

	cc := newConnectCounter(cfg.Stage)
	prometheus.MustRegister(cc)

	go serveMetrics(cfg.MetricsAddr)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	awsCfg, err := buildAWSConfig(ctx, cfg)
	if err != nil {
		log.Fatalf("FATAL: aws config: %v", err)
	}
	ddb := dynamodb.NewFromConfig(awsCfg)

	log.Printf("polling %s[metric=%s] every %s (stage=%s)", cfg.Table, cfg.MetricKey, cfg.PollInterval, cfg.Stage)
	poll(ctx, ddb, cfg, cc) // prime immediately
	ticker := time.NewTicker(cfg.PollInterval)
	defer ticker.Stop()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	for {
		select {
		case <-ticker.C:
			poll(ctx, ddb, cfg, cc)
		case sig := <-sigCh:
			log.Printf("received %s, shutting down", sig)
			return
		}
	}
}
