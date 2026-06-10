// edge-gateway subscribes to the EMQX shared-subscription group `$share/edge-gw/...`,
// detects occupancy state changes per room_id, restores cache from InfluxDB on miss,
// and writes the latest state to DynamoDB via IAM Roles Anywhere temporary credentials.
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials/processcreds"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	ddtypes "github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
	mqtt "github.com/eclipse/paho.mqtt.golang"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const (
	topicPrefix = "sensors/"
	topicSuffix = "/occupancy"
	metricsAddr = ":9101"
)

// Prometheus 계측 — visibility phase 스크랩 타겟(edge-gateway.svc:9101/metrics).
// PutItem(DynamoDB egress) 와 STS(IAM Roles Anywhere) 자격증명 갱신 성공/실패를 노출.
var (
	putItemTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "edge_gateway_dynamodb_putitem_total",
		Help: "DynamoDB PutItem attempts, by table and result (success|error).",
	}, []string{"table", "result"})

	stsRefreshTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "edge_gateway_sts_refresh_total",
		Help: "IAM Roles Anywhere credential refreshes, by result (success|error).",
	}, []string{"result"})
)

// serveMetrics 는 /metrics 를 metricsAddr 에서 노출(블로킹) — main 에서 goroutine 으로 기동.
func serveMetrics() {
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())
	srv := &http.Server{Addr: metricsAddr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	log.Printf("metrics server listening on %s/metrics", metricsAddr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Printf("WARN: metrics server stopped: %v", err)
	}
}

// countingCredsProvider 는 자격증명 공급자를 감싸 Retrieve(=STS 갱신) 결과를 계측.
type countingCredsProvider struct{ inner aws.CredentialsProvider }

func (c countingCredsProvider) Retrieve(ctx context.Context) (aws.Credentials, error) {
	creds, err := c.inner.Retrieve(ctx)
	if err != nil {
		stsRefreshTotal.WithLabelValues("error").Inc()
	} else {
		stsRefreshTotal.WithLabelValues("success").Inc()
	}
	return creds, err
}

type Config struct {
	EMQXBrokerURL  string
	EMQXShareTopic string
	InfluxDBURL    string
	InfluxDBBucket string
	InfluxDBToken  string
	DynamoTables   []string
	AWSRegion      string
	TrustAnchorARN string
	ProfileARN     string
	RoleARN        string
	TLSCertFile    string
	TLSKeyFile     string
	TLSCAFile      string
	MappingFile    string
	PodName        string
	SigningHelper  string
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

// mustEnvList parses a comma-separated env var into a trimmed, non-empty list.
// Fan-out targets (e.g. dev + prod DynamoDB tables) are configured this way;
// drop a table from the list to stop writing to it.
func mustEnvList(k string) []string {
	v := mustEnv(k)
	var out []string
	for _, p := range strings.Split(v, ",") {
		if t := strings.TrimSpace(p); t != "" {
			out = append(out, t)
		}
	}
	if len(out) == 0 {
		log.Fatalf("FATAL: env %s required (non-empty)", k)
	}
	return out
}

func loadConfig() *Config {
	return &Config{
		EMQXBrokerURL:  mustEnv("EMQX_BROKER_URL"),
		EMQXShareTopic: envOr("EMQX_SHARE_TOPIC", "$share/edge-gw/sensors/+/occupancy"),
		InfluxDBURL:    mustEnv("INFLUXDB_URL"),
		InfluxDBBucket: envOr("INFLUXDB_BUCKET", "gikview"),
		InfluxDBToken:  mustEnv("INFLUXDB_TOKEN"),
		DynamoTables:   mustEnvList("DYNAMODB_TABLES"),
		AWSRegion:      mustEnv("AWS_DEFAULT_REGION"),
		TrustAnchorARN: mustEnv("TRUST_ANCHOR_ARN"),
		ProfileARN:     mustEnv("PROFILE_ARN"),
		RoleARN:        mustEnv("ROLE_ARN"),
		TLSCertFile:    envOr("TLS_CERT_FILE", "/tls/tls.crt"),
		TLSKeyFile:     envOr("TLS_KEY_FILE", "/tls/tls.key"),
		TLSCAFile:      envOr("TLS_CA_FILE", "/tls/ca.crt"),
		MappingFile:    envOr("DEVICE_ROOM_MAPPING_FILE", "/mapping/mapping.csv"),
		PodName:        envOr("POD_NAME", "edge-gateway"),
		SigningHelper:  envOr("AWS_SIGNING_HELPER", "/usr/local/bin/aws_signing_helper"),
	}
}

type payload struct {
	Occupied  bool   `json:"occupied"`
	Timestamp string `json:"timestamp"`
	BSSID     string `json:"bssid"`
	RSSI      int    `json:"rssi"`
}

type roomState struct {
	Occupied  bool
	Timestamp string
}

type cache struct {
	mu sync.RWMutex
	m  map[string]roomState
}

func newCache() *cache { return &cache{m: map[string]roomState{}} }

func (c *cache) get(room string) (roomState, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	s, ok := c.m[room]
	return s, ok
}

func (c *cache) set(room string, s roomState) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.m[room] = s
}

type influxClient struct {
	base   string
	bucket string
	token  string
	http   *http.Client
}

// last fetches the most recent (occupied, time) for room from InfluxDB 3 Core.
// Empty result means no prior row — treated as cache miss with no restoration.
func (i *influxClient) last(ctx context.Context, room string) (roomState, bool, error) {
	q := fmt.Sprintf(
		`SELECT occupied, time FROM occupancy WHERE room_id = '%s' ORDER BY time DESC LIMIT 1`,
		strings.ReplaceAll(room, "'", "''"),
	)
	body, _ := json.Marshal(map[string]string{"db": i.bucket, "q": q, "format": "json"})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, i.base+"/api/v3/query_sql", strings.NewReader(string(body)))
	if err != nil {
		return roomState{}, false, err
	}
	req.Header.Set("Authorization", "Bearer "+i.token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := i.http.Do(req)
	if err != nil {
		return roomState{}, false, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode/100 != 2 {
		return roomState{}, false, fmt.Errorf("query %s — %s", resp.Status, snippet(raw))
	}
	var rows []struct {
		Occupied bool   `json:"occupied"`
		Time     string `json:"time"`
	}
	if err := json.Unmarshal(raw, &rows); err != nil {
		return roomState{}, false, fmt.Errorf("decode: %w (raw=%s)", err, snippet(raw))
	}
	if len(rows) == 0 {
		return roomState{}, false, nil
	}
	return roomState{Occupied: rows[0].Occupied, Timestamp: rows[0].Time}, true, nil
}

func snippet(b []byte) string {
	const n = 200
	s := string(b)
	if len(s) > n {
		return s[:n] + "..."
	}
	return s
}

type dynamoWriter struct {
	client *dynamodb.Client
	tables []string
}

// put fans the room state out to every configured table. All tables share one
// region/client, so a single PutItem loop suffices. A failure on one table does
// not skip the rest; errors are joined. PutItem is idempotent, so a retry after
// partial failure safely re-writes the table(s) that already succeeded.
func (d *dynamoWriter) put(ctx context.Context, room string, s roomState) error {
	item := map[string]ddtypes.AttributeValue{
		"room_id":   &ddtypes.AttributeValueMemberS{Value: room},
		"occupied":  &ddtypes.AttributeValueMemberBOOL{Value: s.Occupied},
		"timestamp": &ddtypes.AttributeValueMemberS{Value: s.Timestamp},
	}
	var errs []error
	for _, table := range d.tables {
		if _, err := d.client.PutItem(ctx, &dynamodb.PutItemInput{
			TableName: aws.String(table),
			Item:      item,
		}); err != nil {
			putItemTotal.WithLabelValues(table, "error").Inc()
			errs = append(errs, fmt.Errorf("table %s: %w", table, err))
		} else {
			putItemTotal.WithLabelValues(table, "success").Inc()
		}
	}
	return errors.Join(errs...)
}

func loadMapping(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	r := csv.NewReader(f)
	r.FieldsPerRecord = -1
	out := map[string]string{}
	for {
		rec, err := r.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		if len(rec) < 2 {
			continue
		}
		dev := strings.TrimSpace(rec[0])
		room := strings.TrimSpace(rec[1])
		if dev == "" || room == "" || strings.HasPrefix(dev, "#") {
			continue
		}
		out[dev] = room
	}
	return out, nil
}

func loadTLS(certFile, keyFile, caFile string) (*tls.Config, error) {
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, fmt.Errorf("load client cert: %w", err)
	}
	caPEM, err := os.ReadFile(caFile)
	if err != nil {
		return nil, fmt.Errorf("read ca: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		return nil, fmt.Errorf("parse ca bundle")
	}
	return &tls.Config{
		RootCAs:      pool,
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS12,
	}, nil
}

func deviceFromTopic(topic string) (string, bool) {
	if !strings.HasPrefix(topic, topicPrefix) || !strings.HasSuffix(topic, topicSuffix) {
		return "", false
	}
	inner := strings.TrimSuffix(strings.TrimPrefix(topic, topicPrefix), topicSuffix)
	if inner == "" || strings.Contains(inner, "/") {
		return "", false
	}
	return inner, true
}

func serverName(rawURL string) (string, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return "", err
	}
	return u.Hostname(), nil
}

// buildAWSConfig wires the AWS SDK to obtain credentials via aws_signing_helper
// (IAM Roles Anywhere) using credential_process, with the Edge Gateway mTLS cert
// as the trust material.
func buildAWSConfig(ctx context.Context, cfg *Config) (aws.Config, error) {
	cmd := fmt.Sprintf(
		"%s credential-process --certificate %s --private-key %s --trust-anchor-arn %s --profile-arn %s --role-arn %s --region %s",
		cfg.SigningHelper,
		cfg.TLSCertFile, cfg.TLSKeyFile,
		cfg.TrustAnchorARN, cfg.ProfileARN, cfg.RoleARN, cfg.AWSRegion,
	)
	prov := processcreds.NewProvider(cmd)
	return awsconfig.LoadDefaultConfig(ctx,
		awsconfig.WithRegion(cfg.AWSRegion),
		awsconfig.WithCredentialsProvider(aws.NewCredentialsCache(countingCredsProvider{inner: prov})),
	)
}

func handleMessage(
	ctx context.Context,
	msg mqtt.Message,
	mapping map[string]string,
	state *cache,
	influx *influxClient,
	ddb *dynamoWriter,
) error {
	device, ok := deviceFromTopic(msg.Topic())
	if !ok {
		return fmt.Errorf("malformed topic %q", msg.Topic())
	}
	room, ok := mapping[device]
	if !ok {
		return fmt.Errorf("device %s not in mapping", device)
	}
	var p payload
	if err := json.Unmarshal(msg.Payload(), &p); err != nil {
		return fmt.Errorf("decode payload: %w", err)
	}
	next := roomState{Occupied: p.Occupied, Timestamp: p.Timestamp}

	cur, hit := state.get(room)
	if !hit {
		restored, found, err := influx.last(ctx, room)
		switch {
		case err != nil:
			log.Printf("WARN: influx restore room=%s: %v (proceeding as changed)", room, err)
		case found:
			cur = restored
			hit = true
			state.set(room, restored)
		}
	}
	if hit && cur.Occupied == next.Occupied {
		return nil
	}

	putCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := ddb.put(putCtx, room, next); err != nil {
		return fmt.Errorf("dynamodb put room=%s: %w", room, err)
	}
	state.set(room, next)
	log.Printf("state change: room=%s occupied=%v ts=%s device=%s", room, next.Occupied, next.Timestamp, device)
	return nil
}

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	cfg := loadConfig()

	go serveMetrics()

	// 카운터 0-초기화 — 첫 트래픽(PutItem/STS 갱신) 전에도 시리즈를 노출해 대시보드 No-data 방지.
	for _, t := range cfg.DynamoTables {
		putItemTotal.WithLabelValues(t, "success").Add(0)
		putItemTotal.WithLabelValues(t, "error").Add(0)
	}
	stsRefreshTotal.WithLabelValues("success").Add(0)
	stsRefreshTotal.WithLabelValues("error").Add(0)

	mapping, err := loadMapping(cfg.MappingFile)
	if err != nil {
		log.Fatalf("FATAL: mapping %s: %v", cfg.MappingFile, err)
	}
	log.Printf("loaded device-room mapping: %d entries", len(mapping))

	tlsCfg, err := loadTLS(cfg.TLSCertFile, cfg.TLSKeyFile, cfg.TLSCAFile)
	if err != nil {
		log.Fatalf("FATAL: tls: %v", err)
	}
	if sn, err := serverName(cfg.EMQXBrokerURL); err == nil && sn != "" {
		tlsCfg.ServerName = sn
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	awsCfg, err := buildAWSConfig(ctx, cfg)
	if err != nil {
		log.Fatalf("FATAL: aws config: %v", err)
	}
	ddb := &dynamoWriter{client: dynamodb.NewFromConfig(awsCfg), tables: cfg.DynamoTables}

	influx := &influxClient{
		base:   strings.TrimRight(cfg.InfluxDBURL, "/"),
		bucket: cfg.InfluxDBBucket,
		token:  cfg.InfluxDBToken,
		http:   &http.Client{Timeout: 10 * time.Second},
	}

	state := newCache()
	clientID := "edge-gateway-" + cfg.PodName

	handler := func(_ mqtt.Client, msg mqtt.Message) {
		if err := handleMessage(ctx, msg, mapping, state, influx, ddb); err != nil {
			log.Printf("ERROR: handle %s: %v", msg.Topic(), err)
		}
	}

	opts := mqtt.NewClientOptions().
		AddBroker(cfg.EMQXBrokerURL).
		SetClientID(clientID).
		SetTLSConfig(tlsCfg).
		SetCleanSession(true).
		SetAutoReconnect(true).
		SetConnectRetry(true).
		SetConnectRetryInterval(5 * time.Second).
		SetKeepAlive(30 * time.Second).
		SetOrderMatters(false).
		SetOnConnectHandler(func(c mqtt.Client) {
			if t := c.Subscribe(cfg.EMQXShareTopic, 1, handler); t.Wait() && t.Error() != nil {
				log.Fatalf("FATAL: subscribe %s: %v", cfg.EMQXShareTopic, t.Error())
			}
			log.Printf("subscribed: %s as %s", cfg.EMQXShareTopic, clientID)
		}).
		SetConnectionLostHandler(func(_ mqtt.Client, err error) {
			log.Printf("WARN: mqtt connection lost: %v", err)
		})

	client := mqtt.NewClient(opts)
	if t := client.Connect(); t.Wait() && t.Error() != nil {
		log.Fatalf("FATAL: mqtt connect %s: %v", cfg.EMQXBrokerURL, t.Error())
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	sig := <-sigCh
	log.Printf("received %s, shutting down", sig)
	client.Disconnect(2000)
}
