package syncbff

import (
	"context"
	"net/http"
	"sort"
	"strconv"
	"time"
)

type SnapshotOptions struct {
	Enabled        bool `json:"enabled"`
	MaxChanges     int  `json:"maxChanges"`
	MaxReplayBytes int  `json:"maxReplayBytes"`
}
type HeadReader interface {
	Head(context.Context, string, string) (int64, string, error)
}

func (s *MemoryStore) Head(ctx context.Context, scope, session string) (int64, string, error) {
	if err := ctx.Err(); err != nil {
		return 0, session, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.partition(scope).Sequence, session, nil
}
func (s *CosmosStore) Head(ctx context.Context, scope, session string) (int64, string, error) {
	head, _, session, err := s.read(ctx, scope, "head", session)
	if err != nil {
		return 0, session, err
	}
	if head == nil {
		return 0, session, nil
	}
	return head.Sequence, session, nil
}

func (s *Server) serveSnapshot(w http.ResponseWriter, r *http.Request, scope Scope, accessToken, session string) {
	if !s.config.Snapshots.Enabled {
		s.writeError(w, protocolError(404, "not_found"))
		return
	}
	if !scope.CanRead {
		s.writeError(w, protocolError(403, "forbidden"))
		return
	}
	reader, ok := s.store.(HeadReader)
	if !ok {
		s.writeError(w, protocolError(503, "snapshot_unavailable"))
		return
	}
	limit := 100
	if text := r.URL.Query().Get("limit"); text != "" {
		value, err := strconv.Atoi(text)
		if err != nil || value < 1 || value > 100 {
			s.writeError(w, protocolError(400, "invalid_limit"))
			return
		}
		limit = value
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	var cutover int64
	offset := 0
	if cursors, ok := r.URL.Query()["cursor"]; ok {
		if len(cursors) != 1 {
			s.writeError(w, protocolError(410, "resync_required"))
			return
		}
		value, err := s.verifyContext("snapshot-v1", cursors[0], scope)
		if err != nil || value.Sequence < 0 || value.Sequence > MaxSequence || value.Offset < 0 {
			s.writeError(w, protocolError(410, "resync_required"))
			return
		}
		cutover, offset = value.Sequence, value.Offset
	} else {
		var err error
		cutover, session, err = reader.Head(ctx, scope.ID, session)
		if err != nil {
			s.writeError(w, err)
			return
		}
	}
	maximum := s.config.Snapshots.MaxChanges
	if maximum == 0 {
		maximum = 4096
	}
	budget := s.config.Snapshots.MaxReplayBytes
	if budget == 0 {
		budget = 64 * 1024 * 1024
	}
	documents, token, err := foldSnapshot(ctx, s.store, scope.ID, cutover, maximum, budget, session)
	session = token
	if err != nil {
		s.writeError(w, err)
		return
	}
	if offset > len(documents) {
		s.writeError(w, protocolError(410, "resync_required"))
		return
	}
	end := min(offset+limit, len(documents))
	page := documents[offset:end]
	end = offset + boundedDocumentCount(page, s.controls.options.MaxSyncPageBytes)
	page = documents[offset:end]
	if len(page) == 0 && end < len(documents) {
		s.writeError(w, protocolError(413, "snapshot_limit_exceeded"))
		return
	}
	hasMore := end < len(documents)
	if err := s.reauthorizeScope(ctx, accessToken, scope, session); err != nil {
		s.writeError(w, err)
		return
	}
	value := s.boundContext(scope, cutover)
	value.Offset = end
	cursor := s.sign("snapshot-v1", value)
	syncCursor := s.sign("cursor-v1", s.boundContext(scope, cutover))
	if session != "" {
		context := s.boundContext(scope, 0)
		context.Token = session
		w.Header().Set(SessionHeader, s.sign("session-v1", context))
	}
	writeJSON(w, 200, map[string]any{"documents": page, "cursor": cursor, "syncCursor": syncCursor, "cutoverSequence": cutover, "hasMore": hasMore})
}

func foldSnapshot(ctx context.Context, store Store, scope string, cutover int64, maxChanges, maxBytes int, session string) ([]Document, string, error) {
	latest := map[string]Document{}
	var after int64
	count, consumed := 0, 0
	for after < cutover {
		if err := ctx.Err(); err != nil {
			return nil, session, err
		}
		previous := after
		page, token, err := store.Sync(ctx, scope, after, 100, session)
		session = token
		if err != nil {
			return nil, session, err
		}
		if len(page.Changes) == 0 {
			return nil, session, &ProtocolError{Status: 503, Code: "sync_gap_retry", RetryAfter: "1"}
		}
		for _, document := range page.Changes {
			if document.Version > cutover {
				break
			}
			if document.Version != after+1 {
				return nil, session, &ProtocolError{Status: 503, Code: "sync_gap_retry", RetryAfter: "1"}
			}
			count++
			encoded, _ := encodeJSON(document)
			consumed += len(encoded)
			if count > maxChanges || consumed > maxBytes {
				return nil, session, protocolError(413, "snapshot_limit_exceeded")
			}
			latest[document.ID] = cloneDocument(document)
			after = document.Version
		}
		if after == previous {
			return nil, session, &ProtocolError{Status: 503, Code: "sync_gap_retry", RetryAfter: "1"}
		}
	}
	ids := make([]string, 0, len(latest))
	for id := range latest {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	documents := make([]Document, 0, len(ids))
	for _, id := range ids {
		documents = append(documents, latest[id])
	}
	return documents, session, nil
}
func boundedDocumentCount(documents []Document, budget int) int {
	used := 2
	for i, document := range documents {
		body, _ := encodeJSON(document)
		extra := len(body)
		if i > 0 {
			extra++
		}
		if used+extra > budget {
			return i
		}
		used += extra
	}
	return len(documents)
}
