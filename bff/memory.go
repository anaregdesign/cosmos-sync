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
	Sequence               int64
	Documents              map[string]Document
	Journal                []Document
	Receipts               map[string]receipt
	EstimatedRetainedBytes int64
}
type MemoryStore struct {
	mu         sync.Mutex
	partitions map[string]*memoryPartition
	retention  retentionControls
}

func NewMemoryStore() *MemoryStore { return &MemoryStore{partitions: map[string]*memoryPartition{}} }
func (s *MemoryStore) ConfigureRetention(options RetentionOptions) error {
	return s.retention.configure(options)
}
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
	if receipt, ok := p.Receipts[mutationReceiptKey(m)]; ok {
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
	doc := Document{ID: m.DocumentID, Data: append([]byte(nil), m.Data...), Version: p.Sequence + 1, Deleted: m.Kind == "delete"}
	addition := retainedEstimate(doc)
	if !s.retention.allows(p.Sequence, p.EstimatedRetainedBytes, addition) {
		return Document{}, session, capacityError()
	}
	p.Sequence++
	p.EstimatedRetainedBytes += addition
	p.Documents[doc.ID] = doc
	p.Journal = append(p.Journal, doc)
	p.Receipts[mutationReceiptKey(m)] = receipt{Hash: hash, Document: doc}
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
