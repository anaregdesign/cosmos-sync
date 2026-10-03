package syncbff

import (
	"fmt"
	"sync"
)

// Capacity limits stop new writes; they never expire receipts, journal or tombstones.
type RetentionOptions struct {
	MaxJournalEvents          int64 `json:"maxJournalEvents"`
	MaxEstimatedRetainedBytes int64 `json:"maxEstimatedRetainedBytes"`
}
type RetentionConfigurable interface{ ConfigureRetention(RetentionOptions) error }
type retentionControls struct {
	mu      sync.RWMutex
	options RetentionOptions
}

func normalizeRetention(options RetentionOptions) (RetentionOptions, error) {
	if options.MaxJournalEvents == 0 {
		options.MaxJournalEvents = 10000
	}
	if options.MaxEstimatedRetainedBytes == 0 {
		options.MaxEstimatedRetainedBytes = 128 * 1024 * 1024
	}
	if options.MaxJournalEvents < 1 || options.MaxJournalEvents > MaxSequence || options.MaxEstimatedRetainedBytes < 4096 || options.MaxEstimatedRetainedBytes > 16*1024*1024*1024 {
		return options, fmt.Errorf("retention capacity must be positive and below16GiB")
	}
	return options, nil
}
func (c *retentionControls) configure(options RetentionOptions) error {
	value, err := normalizeRetention(options)
	if err != nil {
		return err
	}
	c.mu.Lock()
	c.options = value
	c.mu.Unlock()
	return nil
}
func (c *retentionControls) allows(sequence, estimatedBytes, addition int64) bool {
	c.mu.RLock()
	options := c.options
	c.mu.RUnlock()
	options, _ = normalizeRetention(options)
	return sequence >= 0 && estimatedBytes >= 0 && addition >= 0 && sequence < options.MaxJournalEvents && estimatedBytes <= options.MaxEstimatedRetainedBytes-addition
}

func legacyRetainedEstimate(sequence int64) int64 {
	maximum := int64(3*MaxDocumentBytes + 4096)
	if sequence < 0 || sequence > (16*1024*1024*1024)/maximum {
		return 16*1024*1024*1024 + 1
	}
	return sequence * maximum
}
func capacityError() error { return &ProtocolError{Status: 507, Code: "scope_capacity_exceeded"} }

// Conservative retained estimate includes three document copies plus fixed
// Cosmos item metadata allowance. Replacements add rather than credit old bytes.
func retainedEstimate(document Document) int64 {
	body, _ := encodeJSON(document)
	return int64(3*len(body) + 4096)
}
