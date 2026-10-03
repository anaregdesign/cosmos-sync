package syncbff

import (
	"crypto/subtle"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"
)

type LimitOptions struct {
	Enabled               bool `json:"enabled"`
	MaxConcurrentRequests int  `json:"maxConcurrentRequests"`
	MaxConcurrentStreams  int  `json:"maxConcurrentStreams"`
	RequestsPerMinute     int  `json:"requestsPerMinute"`
	Burst                 int  `json:"burst"`
	MaxPrincipalBuckets   int  `json:"maxPrincipalBuckets"`
	MaxDocumentBytes      int  `json:"maxDocumentBytes"`
	MaxSyncPageBytes      int  `json:"maxSyncPageBytes"`
}
type principalBucket struct {
	tokens  float64
	updated time.Time
}
type runtimeControls struct {
	options  LimitOptions
	requests chan struct{}
	streams  chan struct{}
	mu       sync.Mutex
	buckets  map[string]principalBucket
}

func newRuntimeControls(config Config) (*runtimeControls, error) {
	if config.Events.PollMilliseconds < 0 || config.Events.PollMilliseconds > 60000 || config.Events.HeartbeatMilliseconds < 0 || config.Events.HeartbeatMilliseconds > 30000 || config.Events.MaxStreamSeconds < 0 || config.Events.MaxStreamSeconds > 300 || config.Snapshots.MaxChanges < 0 || config.Snapshots.MaxChanges > 100000 || config.Snapshots.MaxReplayBytes < 0 || config.Snapshots.MaxReplayBytes > 256*1024*1024 {
		return nil, fmt.Errorf("invalid bounded event or snapshot configuration")
	}
	o := config.Limits
	if o.MaxConcurrentRequests == 0 {
		o.MaxConcurrentRequests = 64
	}
	if o.MaxConcurrentStreams == 0 {
		o.MaxConcurrentStreams = 8
	}
	if o.RequestsPerMinute == 0 {
		o.RequestsPerMinute = 120
	}
	if o.Burst == 0 {
		o.Burst = 30
	}
	if o.MaxPrincipalBuckets == 0 {
		o.MaxPrincipalBuckets = 10000
	}
	if o.MaxDocumentBytes == 0 {
		o.MaxDocumentBytes = MaxDocumentBytes
	}
	if o.MaxSyncPageBytes == 0 {
		o.MaxSyncPageBytes = 4 * 1024 * 1024
	}
	if o.MaxConcurrentRequests < 1 || o.MaxConcurrentRequests > 10000 || o.MaxConcurrentStreams < 1 || o.MaxConcurrentStreams > 1000 || o.RequestsPerMinute < 1 || o.Burst < 1 || o.MaxPrincipalBuckets < 1 || o.MaxPrincipalBuckets > 100000 || o.MaxDocumentBytes < 1 || o.MaxDocumentBytes > MaxDocumentBytes || o.MaxSyncPageBytes < MaxDocumentBytes+4096 || o.MaxSyncPageBytes > 64*1024*1024 {
		return nil, fmt.Errorf("invalid operational limit configuration")
	}
	for _, origin := range config.AllowedOrigins {
		u, err := url.Parse(origin)
		if err != nil || u.Host == "" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" || strings.Contains(origin, "*") || !(u.Scheme == "https" || (config.Development && u.Scheme == "http" && (u.Hostname() == "localhost" || u.Hostname() == "127.0.0.1" || u.Hostname() == "::1"))) {
			return nil, fmt.Errorf("allowedOrigins requires exact HTTPS origins (HTTP loopback only in development)")
		}
	}
	return &runtimeControls{options: o, requests: make(chan struct{}, o.MaxConcurrentRequests), streams: make(chan struct{}, o.MaxConcurrentStreams), buckets: map[string]principalBucket{}}, nil
}
func (c *runtimeControls) acquireRequest() bool {
	if !c.options.Enabled {
		return true
	}
	select {
	case c.requests <- struct{}{}:
		return true
	default:
		return false
	}
}
func (c *runtimeControls) releaseRequest() {
	if c.options.Enabled {
		<-c.requests
	}
}
func (c *runtimeControls) acquireStream() bool {
	select {
	case c.streams <- struct{}{}:
		return true
	default:
		return false
	}
}
func (c *runtimeControls) releaseStream() { <-c.streams }
func (c *runtimeControls) allowPrincipal(principal string) bool {
	if !c.options.Enabled {
		return true
	}
	now := time.Now()
	c.mu.Lock()
	defer c.mu.Unlock()
	bucket, exists := c.buckets[principal]
	if !exists {
		if len(c.buckets) >= c.options.MaxPrincipalBuckets {
			for key, value := range c.buckets {
				if now.Sub(value.updated) > time.Minute {
					delete(c.buckets, key)
				}
			}
		}
		if len(c.buckets) >= c.options.MaxPrincipalBuckets {
			return false
		}
		bucket = principalBucket{tokens: float64(c.options.Burst), updated: now}
	}
	bucket.tokens = min(float64(c.options.Burst), bucket.tokens+now.Sub(bucket.updated).Seconds()*float64(c.options.RequestsPerMinute)/60)
	bucket.updated = now
	allowed := bucket.tokens >= 1
	if allowed {
		bucket.tokens--
	}
	c.buckets[principal] = bucket
	return allowed
}

func (s *Server) cors(w http.ResponseWriter, r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		if r.Method == http.MethodOptions {
			s.writeError(w, protocolError(403, "origin_required"))
			return false
		}
		return true
	}
	allowed := false
	for _, candidate := range s.config.AllowedOrigins {
		if origin == candidate {
			allowed = true
			break
		}
	}
	if !allowed {
		s.writeError(w, protocolError(403, "origin_forbidden"))
		return false
	}
	w.Header().Add("Vary", "Origin")
	w.Header().Set("Access-Control-Allow-Origin", origin)
	w.Header().Set("Access-Control-Expose-Headers", SessionHeader+", Retry-After")
	if r.Method != http.MethodOptions {
		return true
	}
	method := r.Header.Get("Access-Control-Request-Method")
	validRoute := ((r.URL.Path == "/v1/session" || r.URL.Path == "/v1/sync" || r.URL.Path == "/v1/events" || r.URL.Path == "/v1/snapshot") && method == http.MethodGet) || (r.URL.Path == "/v1/mutations" && method == http.MethodPost)
	if !validRoute {
		s.writeError(w, protocolError(403, "preflight_forbidden"))
		return false
	}
	headers := []string{"Authorization", "Content-Type", ScopeHeader, PermissionHeader, PrincipalHeader, ScopeModeHeader, SessionHeader, "Last-Event-ID"}
	for _, requested := range strings.Split(r.Header.Get("Access-Control-Request-Headers"), ",") {
		if strings.TrimSpace(requested) == "" {
			continue
		}
		found := false
		for _, allowedHeader := range headers {
			if strings.EqualFold(strings.TrimSpace(requested), allowedHeader) {
				found = true
			}
		}
		if !found {
			s.writeError(w, protocolError(403, "preflight_forbidden"))
			return false
		}
	}
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST")
	w.Header().Set("Access-Control-Allow-Headers", strings.Join(headers, ", "))
	w.Header().Set("Access-Control-Max-Age", "300")
	w.WriteHeader(http.StatusNoContent)
	return false
}

type observedResponse struct {
	http.ResponseWriter
	status  int
	started time.Time
}

func newObservedResponse(w http.ResponseWriter) *observedResponse {
	return &observedResponse{ResponseWriter: w, started: time.Now()}
}
func (w *observedResponse) WriteHeader(status int) {
	if w.status == 0 {
		w.status = status
		w.ResponseWriter.WriteHeader(status)
	}
}
func (w *observedResponse) Write(body []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(200)
	}
	return w.ResponseWriter.Write(body)
}
func (w *observedResponse) Unwrap() http.ResponseWriter { return w.ResponseWriter }
func (w *observedResponse) Flush()                      { _ = w.FlushError() }
func (w *observedResponse) FlushError() error {
	if w.status == 0 {
		w.WriteHeader(200)
	}
	if flush, ok := w.ResponseWriter.(interface{ FlushError() error }); ok {
		return flush.FlushError()
	}
	if flush, ok := w.ResponseWriter.(http.Flusher); ok {
		flush.Flush()
		return nil
	}
	return http.ErrNotSupported
}

type metricKey struct {
	route, method string
	status        int
}
type metricValue struct {
	count   uint64
	seconds float64
}
type metrics struct {
	mu     sync.Mutex
	values map[metricKey]metricValue
}

func newMetrics() *metrics { return &metrics{values: map[metricKey]metricValue{}} }
func (m *metrics) record(r *http.Request, w *observedResponse) {
	route := "other"
	switch r.URL.Path {
	case "/v1/session", "/v1/mutations", "/v1/sync", "/v1/events", "/v1/snapshot", "/healthz", "/metrics":
		route = r.URL.Path
	}
	method := r.Method
	if method != "GET" && method != "POST" && method != "OPTIONS" {
		method = "OTHER"
	}
	status := w.status
	if status == 0 {
		status = 200
	}
	key := metricKey{route, method, status}
	m.mu.Lock()
	defer m.mu.Unlock()
	value := m.values[key]
	value.count++
	value.seconds += time.Since(w.started).Seconds()
	m.values[key] = value
}
func (s *Server) serveMetrics(w http.ResponseWriter, r *http.Request) {
	if s.config.MetricsToken == "" {
		s.writeError(w, protocolError(404, "not_found"))
		return
	}
	auth := strings.Fields(r.Header.Get("Authorization"))
	if len(auth) != 2 || auth[0] != "Bearer" || subtle.ConstantTimeCompare([]byte(auth[1]), []byte(s.config.MetricsToken)) != 1 {
		s.writeError(w, protocolError(401, "unauthorized"))
		return
	}
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	s.metrics.mu.Lock()
	defer s.metrics.mu.Unlock()
	keys := make([]metricKey, 0, len(s.metrics.values))
	for key := range s.metrics.values {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(i, j int) bool {
		a, b := keys[i], keys[j]
		if a.route != b.route {
			return a.route < b.route
		}
		if a.method != b.method {
			return a.method < b.method
		}
		return a.status < b.status
	})
	_, _ = fmt.Fprintln(w, "# TYPE cosmos_sync_requests_total counter\n# TYPE cosmos_sync_request_duration_seconds_sum counter")
	for _, key := range keys {
		value := s.metrics.values[key]
		_, _ = fmt.Fprintf(w, "cosmos_sync_requests_total{route=%q,method=%q,status=%q} %d\ncosmos_sync_request_duration_seconds_sum{route=%q,method=%q,status=%q} %g\n", key.route, key.method, fmt.Sprint(key.status), value.count, key.route, key.method, fmt.Sprint(key.status), value.seconds)
	}
}
