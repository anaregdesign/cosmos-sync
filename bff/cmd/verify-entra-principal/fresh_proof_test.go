package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	syncbff "github.com/anaregdesign/cosmos-sync/bff"
	"github.com/coreos/go-oidc/v3/oidc"
)

type freshDiscoveryTransport struct{ fixture *signerFixture }

func (transport freshDiscoveryTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	f := transport.fixture
	if request.URL.String() == f.config.Issuer+"/.well-known/openid-configuration" {
		copy := request.Clone(request.Context())
		local, _ := url.Parse(f.server.URL + "/.well-known/openid-configuration")
		copy.URL = local
		return f.server.Client().Transport.RoundTrip(copy)
	}
	if request.URL.String() == f.server.URL+"/jwks" {
		return f.server.Client().Transport.RoundTrip(request)
	}
	return nil, code("unexpected_fixture_request")
}

func freshFixture(t *testing.T) (context.Context, options, string) {
	t.Helper()
	f := fixture(t)
	f.config.Issuer = "https://" + testTenant + ".ciamlogin.com/" + testTenant + "/v2.0"
	owner, receipt := validReceipt()
	receipt.OIDC.Issuer = f.config.Issuer
	receipt.OIDC.AllowedClientIDs = []string{testNative}
	callback := "com.anaregdesign.cosmossync://auth/oauthredirect"
	config := syncbff.Config{
		Storage: "cosmos", OIDC: receipt.OIDC,
		Authorization: syncbff.AuthorizationOptions{Mode: "directory", Directory: &syncbff.IdentityDirectoryOptions{
			TenantID: testTenant, InitialDomain: "fixture.onmicrosoft.com",
			ReaderClientID: testOther, ManagedIdentityClientID: "66666666-6666-4666-8666-666666666666",
			WorkforceTenantIDs: []string{"77777777-7777-4777-8777-777777777777"},
			Namespace:          "signed-cli-fixture", Callbacks: []string{callback},
		}},
	}
	directory := t.TempDir()
	write := func(name string, value any) string {
		t.Helper()
		data, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(directory, name)
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	opts := options{FreshProofStdin: true, Callback: callback,
		OwnerFile: write("owner.json", owner), ReceiptFile: write("receipt.json", receipt),
		DirectoryConfigFile: write("config.json", config)}
	challenge := strings.Repeat("a", 64)
	input, err := json.Marshal(map[string]string{
		"challenge":   challenge,
		"accessToken": f.token(t, map[string]any{"azp": testNative}, nil),
		"idToken": f.token(t, map[string]any{
			"aud": testNative, "sub": "different-native-id-subject", "scp": nil,
			"azp": testNative, "nonce": challenge, "iat": time.Now().Unix(),
			"auth_time": time.Now().Add(-time.Second).Unix(),
		}, nil),
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx := oidc.ClientContext(context.Background(), &http.Client{
		Timeout: 3 * time.Second, Transport: freshDiscoveryTransport{f},
	})
	return ctx, opts, string(input)
}

func TestTransientFreshProofCLIUsesSignedSeparateAudiencesAndWritesNothing(t *testing.T) {
	ctx, opts, input := freshFixture(t)
	if err := runFreshProof(ctx, opts, strings.NewReader(input)); err != nil {
		t.Fatal("signed transient proof rejected", err)
	}
	entries, err := os.ReadDir(filepath.Dir(opts.OwnerFile))
	if err != nil || len(entries) != 3 {
		t.Fatal("fresh verification persisted an output or proof")
	}
}

func TestTransientFreshProofCLIRejectsMixedModesAndStrictInput(t *testing.T) {
	ctx, opts, input := freshFixture(t)
	for name, mutate := range map[string]func(*options){
		"token file": func(o *options) { o.TokenFile = "/private/token" },
		"output":     func(o *options) { o.OutputDir = "/private/output" },
		"grant":      func(o *options) { o.PermissionVersion = "would-issue-grant" },
		"callback":   func(o *options) { o.Callback = "https://unapproved.invalid/callback" },
		"mode":       func(o *options) { o.FreshProofStdin = false },
	} {
		t.Run(name, func(t *testing.T) {
			candidate := opts
			mutate(&candidate)
			if err := runFreshProof(ctx, candidate, strings.NewReader(input)); err == nil {
				t.Fatal("mixed or unapproved verification accepted")
			}
		})
	}
	for name, value := range map[string]string{
		"unknown":    strings.TrimSuffix(input, "}") + `,"refreshToken":"never-persist"}`,
		"duplicate":  strings.TrimSuffix(input, "}") + `,"challenge":"` + strings.Repeat("a", 64) + `"}`,
		"extra":      input + `{}`,
		"oversized":  strings.Repeat(" ", 65537),
		"null":       `null`,
		"array":      `[]`,
		"missing":    `{"challenge":"` + strings.Repeat("a", 64) + `"}`,
		"structured": `{"challenge":[],"accessToken":"a.b.c","idToken":"d.e.f"}`,
	} {
		t.Run(name, func(t *testing.T) {
			err := runFreshProof(ctx, opts, strings.NewReader(value))
			if err == nil || strings.Contains(err.Error(), input) || strings.Contains(err.Error(), "never-persist") {
				t.Fatal("invalid transient input accepted or reflected")
			}
		})
	}
	if err := os.Chmod(opts.DirectoryConfigFile, 0644); err != nil {
		t.Fatal(err)
	}
	if err := runFreshProof(ctx, opts, strings.NewReader(input)); err == nil {
		t.Fatal("public directory configuration accepted")
	}
}
