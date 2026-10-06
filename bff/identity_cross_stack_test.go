package syncbff

import (
	"context"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestDirectoryDartLifecycleCrossStack(t *testing.T) {
	if os.Getenv("COSMOS_SYNC_IDENTITY_DART") != "1" {
		t.Skip("explicit disposable Dart identity fixture not requested")
	}
	for _, test := range []struct {
		name      string
		namespace string
	}{
		{"default namespace", ""},
		{"configured namespace", "dart-http-configured-v1"},
	} {
		t.Run(test.name, func(t *testing.T) {
			first := startIdentityHTTPFixture(t, newBrokerProofFixture(t), NewMemoryStore(), test.namespace)
			second := startIdentityHTTPFixture(t, first.broker, first.handler.store, first.options.Namespace)
			runDirectoryDartLifecycle(t, first, second)
		})
	}
}

// This proof issuer exists only inside go test. The production BFF never
// exposes it; actual browser code/PKCE and managed-identity evidence are separate.
func runDirectoryDartLifecycle(t *testing.T, first, second *identityHTTPFixture) {
	t.Helper()
	first.addProfile(brokerTestOther, brokerProofSecondUser)
	proofs := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request struct {
			Nonce      string `json:"nonce"`
			Credential string `json:"credential"`
		}
		if r.Method != http.MethodPost || r.URL.Path != "/proof" || r.URL.RawQuery != "" ||
			decodeIdentityRequest(w, r, &request) != nil || !accountIDPattern.MatchString(request.Nonce) ||
			(request.Credential != "primary" && request.Credential != "secondary") {
			http.Error(w, "invalid signed local fixture request", http.StatusBadRequest)
			return
		}
		var claims map[string]any
		if request.Credential == "secondary" {
			claims = map[string]any{"oid": brokerTestOther}
		}
		writeJSON(w, 200, identityProofRequest{
			first.broker.access(t, claims, 0), first.broker.id(t, request.Nonce, claims, 0),
		})
	}))
	t.Cleanup(proofs.Close)
	directory := t.TempDir()
	certificate := filepath.Join(directory, "fixture.crt")
	if err := os.WriteFile(certificate, pem.EncodeToMemory(&pem.Block{
		Type: "CERTIFICATE", Bytes: first.server.Certificate().Raw,
	}), 0600); err != nil {
		t.Fatal("cannot write private local fixture certificate")
	}
	input, err := json.Marshal(map[string]any{
		"schemaVersion": 2, "authorizationMode": "directory", "validationMode": "signed-test-fixture",
		"url": first.server.URL, "replica": second.server.URL, "proofs": proofs.URL,
		"certificate": certificate, "issuer": first.broker.signed.target.Issuer,
		"clientId": first.broker.signed.target.ClientID, "callback": first.broker.signed.target.Callback,
		"namespace": first.options.Namespace,
		"tokens": map[string]string{"primary": first.broker.access(t, nil, 0),
			"secondary": first.broker.access(t, map[string]any{"oid": brokerTestOther}, 0)},
	})
	if err != nil {
		t.Fatal("cannot encode signed local fixture")
	}
	ready := filepath.Join(directory, "ready.json")
	if os.WriteFile(ready, input, 0600) != nil {
		t.Fatal("cannot write private disposable fixture input")
	}
	dart := os.Getenv("DART_BIN")
	if dart == "" {
		dart = "dart"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, dart, "run", "tool/identity_probe.dart", ready)
	command.Dir = filepath.Join("..", "packages", "cosmos_sync")
	command.WaitDelay = time.Second
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("actual TLS/Dart/SQLite identity fixture failed: %v\n%s", err, output)
	}
	t.Log(string(output))
}
