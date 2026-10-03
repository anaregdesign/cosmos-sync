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
	key, err := base64.StdEncoding.DecodeString(config.CursorKeyBase64)
	if err != nil || len(key) < 32 {
		return nil, fmt.Errorf("cursorKeyBase64 requires at least 32 random bytes shared by replicas")
	}
	if _, ok := store.(*MemoryStore); ok && !config.Development {
		return nil, fmt.Errorf("memory storage is allowed only in development")
	}
	return &Server{config: config, store: store, verifier: verifier, key: key}, nil
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	if !s.config.Development && r.TLS == nil {
		s.writeError(w, protocolError(400, "https_required"))
		return
	}
	if r.URL.Path == "/healthz" && r.Method == http.MethodGet {
		writeJSON(w, 200, map[string]string{"status": "ok"})
		return
	}
	auth := strings.Fields(r.Header.Get("Authorization"))
	if len(auth) != 2 || !strings.EqualFold(auth[0], "Bearer") {
		s.writeError(w, protocolError(401, "unauthorized"))
		return
	}
	scope, err := s.authorize(r.Context(), auth[1])
	if err != nil {
		s.writeError(w, err)
		return
	}
	if r.URL.Path == "/v1/session" && r.Method == http.MethodGet {
		writeJSON(w, 200, scope)
		return
	}
	if r.Header.Get(ScopeHeader) != scope.ID || r.Header.Get(PermissionHeader) != scope.PermissionVersion {
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
			w.Header().Set(SessionHeader, s.sign("session-v1", signedContext{Version: 1, Scope: scope.ID, Permission: scope.PermissionVersion, Token: token}))
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
		hash, e := validateMutation(&mutation, scope.ID)
		if e != nil {
			s.writeError(w, e)
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
		cursor := s.sign("cursor-v1", signedContext{Version: 1, Scope: scope.ID, Permission: scope.PermissionVersion, Sequence: page.Sequence})
		writeJSON(w, 200, map[string]any{"changes": page.Changes, "cursor": cursor, "hasMore": page.HasMore})
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
