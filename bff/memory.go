package syncbff

import (
	"context"
	"sync"
)

type receipt struct {
	Hash     string
	Document Document
}
type memoryPartition struct {
	Sequence  int64
	Documents map[string]Document
	Journal   []Document
	Receipts  map[string]receipt
}
type MemoryStore struct {
	mu         sync.Mutex
	partitions map[string]*memoryPartition
}

func NewMemoryStore() *MemoryStore { return &MemoryStore{partitions: map[string]*memoryPartition{}} }
func (s *MemoryStore) partition(scope string) *memoryPartition {
	p := s.partitions[scope]
	if p == nil {
		p = &memoryPartition{Documents: map[string]Document{}, Journal: []Document{}, Receipts: map[string]receipt{}}
		s.partitions[scope] = p
	}
	return p
}
func (s *MemoryStore) Mutate(ctx context.Context, scope string, m Mutation, hash, session string) (Document, string, error) {
	if err := ctx.Err(); err != nil {
		return Document{}, session, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	p := s.partition(scope)
	if receipt, ok := p.Receipts[m.OperationID]; ok {
		if receipt.Hash != hash {
			return Document{}, session, protocolError(409, "idempotency_mismatch")
		}
		return cloneDocument(receipt.Document), session, nil
	}
	current, exists := p.Documents[m.DocumentID]
	if current.Version != m.BaseVersion {
		var result *Document
		if exists {
			copy := cloneDocument(current)
			result = &copy
		}
		return Document{}, session, &ProtocolError{Status: 409, Code: "conflict", Current: result}
	}
	if p.Sequence >= MaxSequence {
		return Document{}, session, protocolError(503, "sequence_exhausted")
	}
	p.Sequence++
	doc := Document{ID: m.DocumentID, Data: append([]byte(nil), m.Data...), Version: p.Sequence, Deleted: m.Kind == "delete"}
	p.Documents[doc.ID] = doc
	p.Journal = append(p.Journal, doc)
	p.Receipts[m.OperationID] = receipt{Hash: hash, Document: doc}
	return cloneDocument(doc), session, nil
}
func (s *MemoryStore) Sync(ctx context.Context, scope string, after int64, limit int, session string) (StorePage, string, error) {
	if err := ctx.Err(); err != nil {
		return StorePage{}, session, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	p := s.partition(scope)
	if after > p.Sequence {
		return StorePage{}, session, protocolError(410, "resync_required")
	}
	page := StorePage{Changes: []Document{}, Sequence: after}
	for _, doc := range p.Journal {
		if doc.Version <= after {
			continue
		}
		if len(page.Changes) == limit {
			page.HasMore = true
			break
		}
		page.Changes = append(page.Changes, cloneDocument(doc))
		page.Sequence = doc.Version
	}
	return page, session, nil
}
func cloneDocument(d Document) Document { d.Data = append([]byte(nil), d.Data...); return d }
