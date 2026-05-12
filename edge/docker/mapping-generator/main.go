// mapping-generator reads the device->room single-source-of-truth ConfigMap
// (device-room-mapping) and (re)writes three derived ConfigMaps that downstream
// workloads consume:
//
//	emqx-acl          - EMQX file authorizer rules (Erlang terms)
//	step-ca-whitelist - JSON array of allowed device CNs (step-ca initContainer merges it)
//	telegraf-lookup   - device_id,room_id CSV (Telegraf lookup processor)
//
// It talks to the apiserver directly with the pod's ServiceAccount token, so the
// build has zero module dependencies. Output writes are idempotent: a ConfigMap
// is PUT only when its data actually changed (the CronJob runs every 15 min).
package main

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strings"
	"time"
)

const (
	saDir       = "/var/run/secrets/kubernetes.io/serviceaccount"
	sotName     = "device-room-mapping"
	emqxACLName = "emqx-acl"
	whitelistCM = "step-ca-whitelist"
	lookupCM    = "telegraf-lookup"
)

// deviceCN enforces the CN naming rule. A regex must NOT be what step-ca trusts
// (it would admit any 6-hex CN); the explicit whitelist is the gate. This regex
// only filters typos out of the SoT before they reach step-ca-whitelist.
var deviceCN = regexp.MustCompile(`^device-[a-f0-9]{6}$`)

func main() {
	log.SetFlags(0)

	c, err := newClient()
	if err != nil {
		log.Fatalf("FATAL: %v", err)
	}

	sot, ok, err := c.getConfigMap(sotName)
	if err != nil {
		log.Fatalf("FATAL: read %s: %v", sotName, err)
	}
	if !ok {
		log.Fatalf("FATAL: source-of-truth ConfigMap %q not found in namespace %s", sotName, c.namespace)
	}

	pairs := parseSoT(sot.Data) // device_id -> room_id, validated
	devices := make([]string, 0, len(pairs))
	for d := range pairs {
		devices = append(devices, d)
	}
	sort.Strings(devices)
	log.Printf("source-of-truth %s: %d valid device(s)", sotName, len(devices))

	outputs := []struct {
		name string
		data map[string]string
	}{
		{emqxACLName, map[string]string{"acl.conf": renderACL(devices)}},
		{whitelistCM, map[string]string{"whitelist.json": renderWhitelist(devices)}},
		{lookupCM, map[string]string{"lookup.csv": renderLookup(devices, pairs)}},
	}

	failed := false
	for _, o := range outputs {
		changed, err := c.applyConfigMap(o.name, o.data)
		switch {
		case err != nil:
			log.Printf("ERROR: apply %s: %v", o.name, err)
			failed = true
		case changed:
			log.Printf("wrote ConfigMap %s", o.name)
		default:
			log.Printf("ConfigMap %s already up to date", o.name)
		}
	}
	if failed {
		os.Exit(1)
	}
}

// parseSoT joins every data value, splits into lines, and keeps "device,room"
// rows whose device id matches ^device-[a-f0-9]{6}$. Bad rows are logged and
// skipped so a typo never leaks into step-ca-whitelist.
func parseSoT(data map[string]string) map[string]string {
	keys := make([]string, 0, len(data))
	for k := range data {
		keys = append(keys, k)
	}
	sort.Strings(keys) // deterministic logging order

	out := map[string]string{}
	for _, k := range keys {
		for i, raw := range strings.Split(data[k], "\n") {
			line := strings.TrimSpace(raw)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			f := strings.Split(line, ",")
			if len(f) != 2 {
				log.Printf("WARN: %s line %d: expected 'device_id,room_id', got %q - skipped", k, i+1, line)
				continue
			}
			dev, room := strings.TrimSpace(f[0]), strings.TrimSpace(f[1])
			if !deviceCN.MatchString(dev) {
				log.Printf("WARN: %s line %d: device_id %q does not match ^device-[a-f0-9]{6}$ - skipped", k, i+1, dev)
				continue
			}
			if room == "" {
				log.Printf("WARN: %s line %d: device %q has empty room_id - skipped", k, i+1, dev)
				continue
			}
			if prev, dup := out[dev]; dup && prev != room {
				log.Printf("WARN: device %q mapped to both %q and %q - keeping %q", dev, prev, room, prev)
				continue
			}
			out[dev] = room
		}
	}
	return out
}

// renderACL builds the EMQX file authorizer config. CN == peer_cert_as_username,
// so each device may publish only to its own occupancy topic; edge-gateway and
// telegraf get shared subscriptions; everything else is denied.
func renderACL(devices []string) string {
	var b strings.Builder
	b.WriteString("%% Managed by mapping-generator - do not edit.\n")
	b.WriteString("%% Generated from the device-room-mapping ConfigMap.\n\n")
	for _, d := range devices {
		fmt.Fprintf(&b, "{allow, {user, %q}, publish, [\"sensors/%s/occupancy\"]}.\n", d, d)
	}
	b.WriteString("\n")
	b.WriteString("{allow, {user, \"edge-gateway\"}, subscribe, [\"$share/edge-gw/sensors/+/occupancy\"]}.\n")
	b.WriteString("{allow, {user, \"telegraf\"}, subscribe, [\"$share/telegraf/sensors/+/occupancy\"]}.\n")
	b.WriteString("\n")
	b.WriteString("{deny, all}.\n")
	return b.String()
}

// renderWhitelist is the explicit CN allowlist step-ca trusts: a JSON array of
// device CNs. step-ca's merge initContainer jq-merges it into ca.json's
// options.x509.templateData.allowedCNs for the X5C device-bootstrap /
// device-renewal provisioners, whose leaf template's {{ fail }} guard rejects
// any requested CN/SAN not in that list (OSS step-ca has no per-provisioner
// policy block; the guard also requires every SAN to be of type "dns").
func renderWhitelist(devices []string) string {
	if devices == nil {
		devices = []string{}
	}
	out, _ := json.MarshalIndent(devices, "", "  ")
	return string(out) + "\n"
}

// renderLookup is the device_id -> room_id table for Telegraf (headerless CSV).
func renderLookup(devices []string, pairs map[string]string) string {
	var b strings.Builder
	for _, d := range devices {
		fmt.Fprintf(&b, "%s,%s\n", d, pairs[d])
	}
	return b.String()
}

// ── apiserver client (stdlib only) ───────────────────────────────────────────

type client struct {
	base      string
	namespace string
	token     string
	http      *http.Client
}

func newClient() (*client, error) {
	host, port := os.Getenv("KUBERNETES_SERVICE_HOST"), os.Getenv("KUBERNETES_SERVICE_PORT")
	if host == "" || port == "" {
		return nil, fmt.Errorf("not running in-cluster (KUBERNETES_SERVICE_HOST/PORT unset)")
	}
	token, err := os.ReadFile(saDir + "/token")
	if err != nil {
		return nil, fmt.Errorf("read service account token: %w", err)
	}
	ns, err := os.ReadFile(saDir + "/namespace")
	if err != nil {
		return nil, fmt.Errorf("read service account namespace: %w", err)
	}
	caPEM, err := os.ReadFile(saDir + "/ca.crt")
	if err != nil {
		return nil, fmt.Errorf("read service account ca.crt: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		return nil, fmt.Errorf("parse service account ca.crt")
	}
	return &client{
		base:      fmt.Sprintf("https://%s:%s", host, port),
		namespace: strings.TrimSpace(string(ns)),
		token:     strings.TrimSpace(string(token)),
		http: &http.Client{
			Timeout: 15 * time.Second,
			Transport: &http.Transport{
				TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12},
			},
		},
	}, nil
}

type configMap struct {
	APIVersion string            `json:"apiVersion"`
	Kind       string            `json:"kind"`
	Metadata   configMapMeta     `json:"metadata"`
	Data       map[string]string `json:"data,omitempty"`
}

type configMapMeta struct {
	Name            string            `json:"name"`
	Namespace       string            `json:"namespace,omitempty"`
	ResourceVersion string            `json:"resourceVersion,omitempty"`
	Labels          map[string]string `json:"labels,omitempty"`
}

func (c *client) do(method, path string, body []byte) (int, []byte, error) {
	var rdr io.Reader
	if body != nil {
		rdr = bytes.NewReader(body)
	}
	req, err := http.NewRequest(method, c.base+path, rdr)
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, b, nil
}

func (c *client) configMapPath(name string) string {
	if name == "" {
		return fmt.Sprintf("/api/v1/namespaces/%s/configmaps", c.namespace)
	}
	return fmt.Sprintf("/api/v1/namespaces/%s/configmaps/%s", c.namespace, name)
}

func (c *client) getConfigMap(name string) (*configMap, bool, error) {
	code, body, err := c.do("GET", c.configMapPath(name), nil)
	if err != nil {
		return nil, false, err
	}
	switch code {
	case http.StatusOK:
		var cm configMap
		if err := json.Unmarshal(body, &cm); err != nil {
			return nil, false, fmt.Errorf("decode: %w", err)
		}
		return &cm, true, nil
	case http.StatusNotFound:
		return nil, false, nil
	default:
		return nil, false, fmt.Errorf("HTTP %d: %s", code, body)
	}
}

var managedLabels = map[string]string{
	"app.kubernetes.io/name":       "mapping-generator",
	"app.kubernetes.io/managed-by": "mapping-generator",
}

// applyConfigMap creates the ConfigMap or updates it so Data equals want.
// Returns true when it actually wrote (created or changed), false on a no-op.
func (c *client) applyConfigMap(name string, want map[string]string) (bool, error) {
	cur, exists, err := c.getConfigMap(name)
	if err != nil {
		return false, err
	}
	if !exists {
		labels := map[string]string{}
		for k, v := range managedLabels {
			labels[k] = v
		}
		b, _ := json.Marshal(configMap{
			APIVersion: "v1", Kind: "ConfigMap",
			Metadata: configMapMeta{Name: name, Namespace: c.namespace, Labels: labels},
			Data:     want,
		})
		code, body, err := c.do("POST", c.configMapPath(""), b)
		if err != nil {
			return false, err
		}
		if code != http.StatusCreated && code != http.StatusOK {
			return false, fmt.Errorf("create: HTTP %d: %s", code, body)
		}
		return true, nil
	}
	if equalData(cur.Data, want) {
		return false, nil
	}
	cur.APIVersion, cur.Kind = "v1", "ConfigMap"
	cur.Data = want
	if cur.Metadata.Labels == nil {
		cur.Metadata.Labels = map[string]string{}
	}
	for k, v := range managedLabels {
		cur.Metadata.Labels[k] = v
	}
	b, _ := json.Marshal(cur)
	code, body, err := c.do("PUT", c.configMapPath(name), b)
	if err != nil {
		return false, err
	}
	if code != http.StatusOK {
		return false, fmt.Errorf("update: HTTP %d: %s", code, body)
	}
	return true, nil
}

func equalData(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if b[k] != v {
			return false
		}
	}
	return true
}
