package syncbff

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"

	"github.com/coreos/go-oidc/v3/oidc"
)

type Server struct {
	config   Config
	store    Store
	verifier *oidc.IDTokenVerifier
	key      []byte
	controls *runtimeControls
	metrics  *metrics
}

func NewServer(config Config, store Store, verifier *oidc.IDTokenVerifier) (*Server, error) {
	if store == nil || verifier == nil {
		return nil, fmt.Errorf("store and OIDC verifier are required")
	}
	if config.OIDC.TenantClaim == "" {
		config.OIDC.TenantClaim = "tid"
	}
	if config.OIDC.RequiredScope == "" {
		config.OIDC.RequiredScope = "cosmos_sync"
	}
	if config.HistoryEpoch == "" {
		config.HistoryEpoch = "1"
	}
	config.Grants = append([]Grant(nil), config.Grants...)
	config.AllowedOrigins = append([]string(nil), config.AllowedOrigins...)
	if err := validateGrantRoles(config.Grants); err != nil {
		return nil, err
	}
	key, err := base64.StdEncoding.DecodeString(config.CursorKeyBase64)
	if err != nil || len(key) < 32 {
		return nil, fmt.Errorf("cursorKeyBase64 requires at least 32 random bytes shared by replicas")
	}
	if _, ok := store.(*MemoryStore); ok && !config.Development {
		return nil, fmt.Errorf("memory storage is allowed only in development")
	}
	controls, err := newRuntimeControls(config)
	if err != nil {
		return nil, err
	}
	if configurable, ok := store.(RetentionConfigurable); ok {
		if err := configurable.ConfigureRetention(config.Retention); err != nil {
			return nil, err
		}
	}
	return &Server{config: config, store: store, verifier: verifier, key: key, controls: controls, metrics: newMetrics()}, nil
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	observed := newObservedResponse(w)
	w = observed
	defer s.metrics.record(r, observed)
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	if !s.config.Development && r.TLS == nil {
		s.writeError(w, protocolError(400, "https_required"))
		return
	}
	if !s.cors(w, r) {
		return
	}
	if r.URL.Path == "/healthz" && r.Method == http.MethodGet {
		writeJSON(w, 200, map[string]string{"status": "ok"})
		return
	}
	if r.URL.Path == "/metrics" && r.Method == http.MethodGet {
		s.serveMetrics(w, r)
		return
	}
	if !s.controls.acquireRequest() {
		s.writeError(w, &ProtocolError{Status: 429, Code: "concurrency_limit", RetryAfter: "1"})
		return
	}
	defer s.controls.releaseRequest()
	auth := strings.Fields(r.Header.Get("Authorization"))
	if len(auth) != 2 || !strings.EqualFold(auth[0], "Bearer") {
		s.writeError(w, protocolError(401, "unauthorized"))
		return
	}
	mode := r.Header.Get(ScopeModeHeader)
	if r.URL.Path == "/v1/session" {
		mode = r.URL.Query().Get("scope")
	}
	scope, err := s.authorize(r.Context(), auth[1], mode)
	if err != nil {
		s.writeError(w, err)
		return
	}
	if !s.controls.allowPrincipal(scope.PrincipalID) {
		s.writeError(w, &ProtocolError{Status: 429, Code: "rate_limit", RetryAfter: "1"})
		return
	}
	if r.URL.Path == "/v1/session" && r.Method == http.MethodGet {
		writeJSON(w, 200, scope)
		return
	}
	if r.Header.Get(ScopeHeader) != scope.ID || r.Header.Get(PermissionHeader) != scope.PermissionVersion || r.Header.Get(PrincipalHeader) != scope.PrincipalID || r.Header.Get(ScopeModeHeader) != scope.ScopeMode {
		s.writeError(w, protocolError(403, "session_mismatch"))
		return
	}
	var session string
	if envelope := r.Header.Get(SessionHeader); envelope != "" {
		value, e := s.verifyContext("session-v1", envelope, scope)
		if e != nil || value.Token == "" {
			s.writeError(w, protocolError(410, "resync_required"))
			return
		}
		session = value.Token
	}
	setSession := func(token string) {
		if token != "" {
			context := s.boundContext(scope, 0)
			context.Token = token
			w.Header().Set(SessionHeader, s.sign("session-v1", context))
		}
	}
	switch {
	case r.URL.Path == "/v1/mutations" && r.Method == http.MethodPost:
		if !scope.CanWrite {
			s.writeError(w, protocolError(403, "forbidden"))
			return
		}
		body, e := io.ReadAll(http.MaxBytesReader(w, r.Body, MaxBodyBytes))
		if e != nil {
			s.writeError(w, protocolError(400, "document_too_large"))
			return
		}
		if validateJSON(body) != nil {
			s.writeError(w, protocolError(400, "invalid_json"))
			return
		}
		var mutation Mutation
		decoder := json.NewDecoder(bytes.NewReader(body))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&mutation) != nil {
			s.writeError(w, protocolError(400, "invalid_mutation"))
			return
		}
		mutation.PrincipalID = scope.PrincipalID
		hash, e := validateMutation(&mutation, scope.ID)
		if e != nil {
			s.writeError(w, e)
			return
		}
		if len(mutation.Data) > s.controls.options.MaxDocumentBytes {
			s.writeError(w, protocolError(400, "document_too_large"))
			return
		}
		document, token, e := s.store.Mutate(r.Context(), scope.ID, mutation, hash, session)
		setSession(token)
		if e != nil {
			s.writeError(w, e)
			return
		}
		writeJSON(w, 200, map[string]Document{"document": document})
	case r.URL.Path == "/v1/sync" && r.Method == http.MethodGet:
		if !scope.CanRead {
			s.writeError(w, protocolError(403, "forbidden"))
			return
		}
		limit := 100
		if value := r.URL.Query().Get("limit"); value != "" {
			limit, err = strconv.Atoi(value)
			if err != nil || limit < 1 || limit > 100 {
				s.writeError(w, protocolError(400, "invalid_limit"))
				return
			}
		}
		var sequence int64
		if cursors, ok := r.URL.Query()["cursor"]; ok {
			if len(cursors) != 1 {
				s.writeError(w, protocolError(410, "resync_required"))
				return
			}
			value, e := s.verifyContext("cursor-v1", cursors[0], scope)
			if e != nil || value.Sequence < 0 || value.Sequence > MaxSequence {
				s.writeError(w, protocolError(410, "resync_required"))
				return
			}
			sequence = value.Sequence
		}
		page, token, e := s.store.Sync(r.Context(), scope.ID, sequence, limit, session)
		setSession(token)
		if e != nil {
			s.writeError(w, e)
			return
		}
		kept := boundedDocumentCount(page.Changes, s.controls.options.MaxSyncPageBytes)
		if kept < len(page.Changes) {
			if kept == 0 {
				s.writeError(w, protocolError(413, "sync_page_too_large"))
				return
			}
			page.Changes = page.Changes[:kept]
			page.Sequence = page.Changes[kept-1].Version
			page.HasMore = true
		}
		cursor := s.sign("cursor-v1", s.boundContext(scope, page.Sequence))
		writeJSON(w, 200, map[string]any{"changes": page.Changes, "cursor": cursor, "hasMore": page.HasMore})
	case r.URL.Path == "/v1/events" && r.Method == http.MethodGet:
		s.serveEvents(w, r, scope, auth[1], session)
	case r.URL.Path == "/v1/snapshot" && r.Method == http.MethodGet:
		s.serveSnapshot(w, r, scope, session)
	default:
		s.writeError(w, protocolError(404, "not_found"))
	}
}
func (s *Server) writeError(w http.ResponseWriter, err error) {
	var e *ProtocolError
	if !errors.As(err, &e) {
		e = &ProtocolError{Status: 503, Code: "store_unavailable", RetryAfter: "1"}
	}
	if e.Status == 401 {
		w.Header().Set("WWW-Authenticate", "Bearer")
	}
	if e.RetryAfter != "" {
		w.Header().Set("Retry-After", e.RetryAfter)
	}
	body := map[string]any{"code": e.Code}
	if e.Code == "conflict" {
		body["current"] = e.Current
	}
	writeJSON(w, e.Status, body)
}
func writeJSON(w http.ResponseWriter, status int, value any) {
	w.WriteHeader(status)
	encoder := json.NewEncoder(w)
	encoder.SetEscapeHTML(false)
	_ = encoder.Encode(value)
}
