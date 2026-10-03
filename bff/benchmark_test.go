package syncbff

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

// Fixtures are bounded per iteration. testing.B can increase b.N without
// retaining an ever-growing journal in one store. This is not a Cosmos benchmark.
var benchmarkPayload = json.RawMessage(`{"kind":"benchmark","text":"` + strings.Repeat("x", 256) + `"}`)

func operationalMutation(index int) Mutation {
	return Mutation{
		OperationID: fmt.Sprintf("00000000-0000-4000-8000-%012x", index+1),
		DocumentID:  fmt.Sprintf("document-%06d", index),
		PrincipalID: "benchmark-principal",
		Kind:        "put",
		Data:        benchmarkPayload,
	}
}

func seedOperationalStore(tb testing.TB, count int) *MemoryStore {
	tb.Helper()
	store := NewMemoryStore()
	for index := 0; index < count; index++ {
		mutation := operationalMutation(index)
		hash, err := validateMutation(&mutation, "benchmark-scope")
		if err != nil {
			tb.Fatal(err)
		}
		if _, _, err := store.Mutate(context.Background(), "benchmark-scope", mutation, hash, ""); err != nil {
			tb.Fatal(err)
		}
	}
	return store
}

func BenchmarkMemoryValidatedMutations(b *testing.B) {
	for _, count := range []int{1000, 10000} {
		for _, workers := range []int{1, 4, 16} {
			b.Run(fmt.Sprintf("documents=%d/workers=%d", count, workers), func(b *testing.B) {
				mutations := make([]Mutation, count)
				for index := range mutations {
					mutations[index] = operationalMutation(index)
				}
				b.ReportAllocs()
				b.SetBytes(int64(count * len(benchmarkPayload)))
				b.ResetTimer()
				started := time.Now()
				for iteration := 0; iteration < b.N; iteration++ {
					store := NewMemoryStore()
					failures := make(chan error, workers)
					var group sync.WaitGroup
					for worker := 0; worker < workers; worker++ {
						group.Add(1)
						go func(worker int) {
							defer group.Done()
							for index := worker; index < count; index += workers {
								mutation := mutations[index]
								hash, err := validateMutation(&mutation, "benchmark-scope")
								if err == nil {
									_, _, err = store.Mutate(context.Background(), "benchmark-scope", mutation, hash, "")
								}
								if err != nil {
									failures <- err
									return
								}
							}
						}(worker)
					}
					group.Wait()
					close(failures)
					for err := range failures {
						b.Fatal(err)
					}
					head, _, err := store.Head(context.Background(), "benchmark-scope", "")
					if err != nil || head != int64(count) {
						b.Fatalf("head = %d, error = %v", head, err)
					}
				}
				elapsed := time.Since(started)
				b.ReportMetric(float64(b.N*count)/elapsed.Seconds(), "mutations/s")
				b.ReportMetric(float64(elapsed.Nanoseconds())/float64(b.N*count), "ns/mutation")
			})
		}
	}
}

func BenchmarkMemoryPaginatedReplay(b *testing.B) {
	for _, count := range []int{1000, 10000} {
		b.Run(fmt.Sprintf("history=%d/page=100", count), func(b *testing.B) {
			store := seedOperationalStore(b, count)
			b.ReportAllocs()
			b.SetBytes(int64(count * len(benchmarkPayload)))
			b.ResetTimer()
			for iteration := 0; iteration < b.N; iteration++ {
				var after int64
				replayed := 0
				for after < int64(count) {
					page, _, err := store.Sync(context.Background(), "benchmark-scope", after, 100, "")
					if err != nil || len(page.Changes) == 0 || page.Sequence <= after {
						b.Fatalf("replay stalled at %d: %+v, %v", after, page, err)
					}
					after = page.Sequence
					replayed += len(page.Changes)
				}
				if replayed != count || after != int64(count) {
					b.Fatalf("replayed %d, cursor %d; expected %d", replayed, after, count)
				}
			}
		})
	}
}

func BenchmarkMemoryTailRead(b *testing.B) {
	for _, count := range []int{1000, 10000} {
		b.Run(fmt.Sprintf("history=%d/last=100", count), func(b *testing.B) {
			store := seedOperationalStore(b, count)
			b.ReportAllocs()
			b.SetBytes(int64(100 * len(benchmarkPayload)))
			b.ResetTimer()
			for iteration := 0; iteration < b.N; iteration++ {
				page, _, err := store.Sync(context.Background(), "benchmark-scope", int64(count-100), 100, "")
				if err != nil || len(page.Changes) != 100 || page.Sequence != int64(count) || page.HasMore {
					b.Fatalf("incorrect tail page: %+v, %v", page, err)
				}
			}
		})
	}
}

func BenchmarkMemorySnapshotFold(b *testing.B) {
	for _, count := range []int{1000, 10000} {
		b.Run(fmt.Sprintf("history=%d/live=%d", count, count), func(b *testing.B) {
			store := seedOperationalStore(b, count)
			b.ReportAllocs()
			b.SetBytes(int64(count * len(benchmarkPayload)))
			b.ResetTimer()
			for iteration := 0; iteration < b.N; iteration++ {
				documents, _, err := foldSnapshot(context.Background(), store, "benchmark-scope", int64(count), count, count*(len(benchmarkPayload)+256), "")
				if err != nil || len(documents) != count {
					b.Fatalf("fold count %d, error %v", len(documents), err)
				}
			}
		})
	}
}

func TestOperationalSnapshotBudgetBoundaries(t *testing.T) {
	store := seedOperationalStore(t, 3)
	page, _, err := store.Sync(context.Background(), "benchmark-scope", 0, 100, "")
	if err != nil {
		t.Fatal(err)
	}
	exactBytes := 0
	for _, document := range page.Changes {
		body, err := encodeJSON(document)
		if err != nil {
			t.Fatal(err)
		}
		exactBytes += len(body)
	}
	for _, test := range []struct {
		name        string
		changes     int
		bytes       int
		shouldLimit bool
	}{
		{"exact bounds", 3, exactBytes, false},
		{"one change below", 2, exactBytes, true},
		{"one byte below", 3, exactBytes - 1, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			documents, _, err := foldSnapshot(context.Background(), store, "benchmark-scope", 3, test.changes, test.bytes, "")
			if test.shouldLimit {
				var protocol *ProtocolError
				if !errors.As(err, &protocol) || protocol.Status != 413 || protocol.Code != "snapshot_limit_exceeded" || documents != nil {
					t.Fatalf("over-budget result = %v, %v", documents, err)
				}
			} else if err != nil || len(documents) != 3 {
				t.Fatalf("exact-budget result = %v, %v", documents, err)
			}
			// A failed fold must not prune the journal or consume any sequence.
			after, _, syncErr := store.Sync(context.Background(), "benchmark-scope", 0, 100, "")
			if syncErr != nil || len(after.Changes) != 3 || after.Sequence != 3 {
				t.Fatalf("snapshot changed retained history: %+v, %v", after, syncErr)
			}
		})
	}
}

// Opt-in evidence collection keeps ordinary tests small and timing-independent.
// Memory measurements are Go-managed allocation/heap, not process RSS or disk.
func TestMemoryOperationalProfile(t *testing.T) {
	if os.Getenv("COSMOS_SYNC_RUN_BENCHMARK") != "1" {
		t.Skip("set COSMOS_SYNC_RUN_BENCHMARK=1 for the bounded allocation profile")
	}
	for _, count := range []int{1000, 10000} {
		runtime.GC()
		var before, after runtime.MemStats
		runtime.ReadMemStats(&before)
		started := time.Now()
		store := seedOperationalStore(t, count)
		elapsed := time.Since(started)
		runtime.GC()
		runtime.ReadMemStats(&after)
		retained := int64(after.HeapAlloc) - int64(before.HeapAlloc)
		store.mu.Lock()
		estimatedRetained := store.partition("benchmark-scope").EstimatedRetainedBytes
		store.mu.Unlock()
		value := map[string]any{
			"go": runtime.Version(), "os": runtime.GOOS, "arch": runtime.GOARCH,
			"logicalCPUs": runtime.NumCPU(), "gomaxprocs": runtime.GOMAXPROCS(0),
			"documents": count, "payloadBytes": len(benchmarkPayload),
			"mutationMilliseconds":   float64(elapsed.Nanoseconds()) / 1e6,
			"retainedHeapDeltaBytes": retained, "allocatedBytes": after.TotalAlloc - before.TotalAlloc,
			"estimatedServerRetainedBytes": estimatedRetained,
			"heapInUseBytes":               after.HeapInuse, "persistentDiskBytes": 0,
		}
		body, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		t.Logf("operational-profile %s", body)
		runtime.KeepAlive(store)
	}
}
