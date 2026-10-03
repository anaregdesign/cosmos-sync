package integration

import (
	"encoding/json"
	"encoding/pem"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	syncbff "github.com/anaregdesign/cosmos-sync/bff"
)

// This opt-in fixture runs the actual built-in authorization HTTP stack. Its
// issuer verifies signed JWTs through discovery/JWKS; identities are disposable
// test subjects, not additional Entra users. The Dart client trusts this one
// ephemeral TLS certificate instead of disabling certificate validation.
func TestDartAuthorizationFixture(t *testing.T) {
	readyFile := os.Getenv("COSMOS_SYNC_AUTHORIZATION_READY_FILE")
	stopFile := os.Getenv("COSMOS_SYNC_AUTHORIZATION_STOP_FILE")
	if readyFile == "" || stopFile == "" {
		t.Skip("run tools/authorization_cross_stack_smoke.py for Dart/Go authorization integration")
	}
	api := newTestAPI(t, nil, func(config *syncbff.Config) {
		config.Grants = nil
		config.GrantsFile = ""
		config.Authorization.Mode = "builtin"
		config.Events = syncbff.EventOptions{Enabled: true, PollMilliseconds: 10, HeartbeatMilliseconds: 20, MaxStreamSeconds: 5}
		config.Snapshots.Enabled = true
	})
	server := httptest.NewTLSServer(api.handler)
	t.Cleanup(server.Close)
	certificate := filepath.Join(filepath.Dir(readyFile), "bff-ca.pem")
	if err := os.WriteFile(certificate, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw}), 0600); err != nil {
		t.Fatal("write disposable BFF certificate:", err)
	}
	t.Cleanup(func() { _ = os.Remove(certificate) })
	ready, err := json.Marshal(map[string]any{
		"url":         server.URL,
		"certificate": certificate,
		"tokens": map[string]string{
			"owner":         api.issuer.token(t, map[string]any{"sub": "fixture-owner", "tid": nil, "email": "same@example.test"}),
			"member":        api.issuer.token(t, map[string]any{"sub": "fixture-member", "tid": nil, "email": "same@example.test"}),
			"ungranted":     api.issuer.token(t, map[string]any{"sub": "fixture-ungranted", "roles": []string{"owner", "admin"}}),
			"wrongAudience": api.issuer.token(t, map[string]any{"sub": "fixture-owner", "aud": "different-api"}),
		},
	})
	if err != nil {
		t.Fatal("encode disposable fixture configuration:", err)
	}
	// Atomic rename prevents the orchestrator from observing partial JSON.
	if err := os.WriteFile(readyFile+".tmp", ready, 0600); err != nil {
		t.Fatal("write disposable fixture configuration:", err)
	}
	if err := os.Rename(readyFile+".tmp", readyFile); err != nil {
		t.Fatal("publish disposable fixture configuration:", err)
	}
	t.Cleanup(func() { _ = os.Remove(readyFile) })
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	deadline := time.NewTimer(50 * time.Second)
	defer deadline.Stop()
	for {
		select {
		case <-ticker.C:
			if _, err := os.Stat(stopFile); err == nil {
				if api.issuer.jwksHits.Load() == 0 {
					t.Fatal("Dart probe did not exercise JWT signature verification")
				}
				return
			} else if !os.IsNotExist(err) {
				t.Fatal("read fixture stop signal:", err)
			}
		case <-deadline.C:
			t.Fatal("Dart authorization fixture exceeded its bounded lifetime")
		}
	}
}
