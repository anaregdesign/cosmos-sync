package syncbff

import (
	"context"
	"fmt"
	"net/http"
	"time"
)

type EventOptions struct {
	Enabled               bool `json:"enabled"`
	PollMilliseconds      int  `json:"pollMilliseconds"`
	HeartbeatMilliseconds int  `json:"heartbeatMilliseconds"`
	MaxStreamSeconds      int  `json:"maxStreamSeconds"`
}

func (s *Server) serveEvents(w http.ResponseWriter, r *http.Request, scope Scope, accessToken, session string) {
	if !s.config.Events.Enabled {
		s.writeError(w, protocolError(404, "not_found"))
		return
	}
	if !scope.CanRead {
		s.writeError(w, protocolError(403, "forbidden"))
		return
	}
	if !s.controls.acquireStream() {
		s.writeError(w, &ProtocolError{Status: 429, Code: "stream_limit", RetryAfter: "1"})
		return
	}
	defer s.controls.releaseStream()
	var sequence int64
	if resume := r.Header.Get("Last-Event-ID"); resume != "" {
		value, err := s.verifyContext("events-v1", resume, scope)
		if err != nil || value.Sequence < 0 || value.Sequence > MaxSequence {
			s.writeError(w, protocolError(410, "resync_required"))
			return
		}
		sequence = value.Sequence
	} else if cursors, ok := r.URL.Query()["cursor"]; ok {
		if len(cursors) != 1 {
			s.writeError(w, protocolError(410, "resync_required"))
			return
		}
		value, err := s.verifyContext("cursor-v1", cursors[0], scope)
		if err != nil || value.Sequence < 0 || value.Sequence > MaxSequence {
			s.writeError(w, protocolError(410, "resync_required"))
			return
		}
		sequence = value.Sequence
	}
	controller := http.NewResponseController(w)
	if err := controller.SetWriteDeadline(time.Now().Add(10 * time.Second)); err != nil && err != http.ErrNotSupported {
		s.writeError(w, protocolError(503, "stream_unavailable"))
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("X-Accel-Buffering", "no")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = fmt.Fprint(w, ": connected\n\n")
	if controller.Flush() != nil {
		return
	}
	poll := s.config.Events.PollMilliseconds
	if poll == 0 {
		poll = 1000
	}
	if poll < 100 && !s.config.Development {
		poll = 100
	}
	heartbeat := s.config.Events.HeartbeatMilliseconds
	if heartbeat == 0 {
		heartbeat = 15000
	}
	lifetime := s.config.Events.MaxStreamSeconds
	if lifetime == 0 {
		lifetime = 60
	}
	ctx, cancel := context.WithTimeout(r.Context(), time.Duration(lifetime)*time.Second)
	defer cancel()
	pollTimer := time.NewTicker(time.Duration(poll) * time.Millisecond)
	defer pollTimer.Stop()
	heartbeatTimer := time.NewTicker(time.Duration(heartbeat) * time.Millisecond)
	defer heartbeatTimer.Stop()
	emit := func(event, id string, value any) bool {
		data, _ := encodeJSON(value)
		_ = controller.SetWriteDeadline(time.Now().Add(10 * time.Second))
		if id != "" {
			if _, err := fmt.Fprintf(w, "id: %s\n", id); err != nil {
				return false
			}
		}
		if _, err := fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, data); err != nil {
			return false
		}
		return controller.Flush() == nil
	}
	check := func() bool {
		current, err := s.authorizeSelected(ctx, accessToken, scope.ScopeMode, scope.ID)
		if ctx.Err() != nil {
			return false
		}
		if err != nil || current.ID != scope.ID || current.PrincipalID != scope.PrincipalID || current.PermissionVersion != scope.PermissionVersion || !current.CanRead {
			code := "forbidden"
			if e, ok := err.(*ProtocolError); ok {
				code = e.Code
			}
			emit("error", "", map[string]string{"code": code})
			return false
		}
		page, token, err := s.store.Sync(ctx, scope.ID, sequence, 100, session)
		session = token
		if ctx.Err() != nil {
			return false
		}
		if err != nil {
			code := "store_unavailable"
			if e, ok := err.(*ProtocolError); ok {
				code = e.Code
			}
			emit("error", "", map[string]string{"code": code})
			return false
		}
		if len(page.Changes) == 0 {
			return true
		}
		// A slow query may span expiry or revocation. Recheck immediately before
		// emitting a hint, rather than only before the storage round trip.
		current, err = s.authorizeSelected(ctx, accessToken, scope.ScopeMode, scope.ID)
		if ctx.Err() != nil {
			return false
		}
		if err != nil || current.ID != scope.ID || current.PrincipalID != scope.PrincipalID || current.PermissionVersion != scope.PermissionVersion || !current.CanRead {
			code := "forbidden"
			if e, ok := err.(*ProtocolError); ok {
				code = e.Code
			}
			emit("error", "", map[string]string{"code": code})
			return false
		}
		sequence = page.Sequence
		resume := s.sign("events-v1", s.boundContext(scope, sequence))
		payload := map[string]any{"cursor": resume}
		if session != "" {
			context := s.boundContext(scope, 0)
			context.Token = session
			payload["session"] = s.sign("session-v1", context)
		}
		return emit("change", resume, payload)
	}
	if !check() {
		return
	}
	for {
		select {
		case <-ctx.Done():
			return
		case <-pollTimer.C:
			if !check() {
				return
			}
		case <-heartbeatTimer.C:
			// Revalidate before every heartbeat as well as every journal poll.
			current, err := s.authorizeSelected(ctx, accessToken, scope.ScopeMode, scope.ID)
			if ctx.Err() != nil {
				return
			}
			if err != nil || current.PermissionVersion != scope.PermissionVersion || current.ID != scope.ID || current.PrincipalID != scope.PrincipalID || !current.CanRead {
				code := "forbidden"
				if e, ok := err.(*ProtocolError); ok {
					code = e.Code
				}
				emit("error", "", map[string]string{"code": code})
				return
			}
			_ = controller.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if _, err := fmt.Fprint(w, ": heartbeat\n\n"); err != nil || controller.Flush() != nil {
				return
			}
		}
	}
}
