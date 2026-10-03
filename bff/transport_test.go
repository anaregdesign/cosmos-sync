package syncbff

import (
	"bytes"
	"context"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/coreos/go-oidc/v3/oidc"
)

type transportTestStore struct{ Store }

func transportServer(t *testing.T, mode string) *Server {
	t.Helper()
	s, err := NewServer(Config{TLSMode: mode, CursorKeyBase64: base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32))}, transportTestStore{NewMemoryStore()}, &oidc.IDTokenVerifier{})
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestContainerAppsModeRequiresProductionAndPlatformMarkers(t *testing.T) {
	t.Setenv("CONTAINER_APP_NAME", "")
	t.Setenv("CONTAINER_APP_REVISION", "")
	config := Config{TLSMode: ContainerAppsTLSMode}
	if validateTLSMode(config) == nil {
		t.Fatal("missing ACA markers accepted")
	}
	t.Setenv("CONTAINER_APP_NAME", "test-app")
	if validateTLSMode(config) == nil {
		t.Fatal("missing revision marker accepted")
	}
	t.Setenv("CONTAINER_APP_REVISION", "test-app--test")
	if err := validateTLSMode(config); err != nil {
		t.Fatal(err)
	}
	config.Development = true
	if validateTLSMode(config) == nil {
		t.Fatal("ACA mode accepted development bypass")
	}
	if validateTLSMode(Config{TLSMode: "generic-proxy"}) == nil {
		t.Fatal("generic proxy mode accepted")
	}
}

func TestDefaultTransportIgnoresForwardedHeadersEvenForProbes(t *testing.T) {
	s := transportServer(t, "")
	for _, path := range []string{"/v1/session", "/metrics", "/healthz", "/readyz"} {
		request := httptest.NewRequest(http.MethodGet, "http://example.test"+path, nil)
		request.Header.Set("X-Forwarded-Proto", "https")
		response := httptest.NewRecorder()
		s.ServeHTTP(response, request)
		if response.Code != 400 {
			t.Fatalf("forwarded header bypassed direct TLS for %s: %d", path, response.Code)
		}
	}
	request := httptest.NewRequest(http.MethodGet, "https://example.test/healthz", nil)
	response := httptest.NewRecorder()
	s.ServeHTTP(response, request)
	if response.Code != 200 {
		t.Fatal("actual direct TLS health probe refused")
	}
}

func TestContainerAppsOnlyAcceptsOneExactHTTPSHeader(t *testing.T) {
	t.Setenv("CONTAINER_APP_NAME", "test-app")
	t.Setenv("CONTAINER_APP_REVISION", "test-app--test")
	s := transportServer(t, ContainerAppsTLSMode)
	for _, values := range [][]string{nil, {"http"}, {"HTTPS"}, {" https"}, {"https,http"}, {"https", "https"}, {"https", "http"}} {
		request := httptest.NewRequest(http.MethodGet, "http://example.test/v1/session", nil)
		request.Header["X-Forwarded-Proto"] = values
		response := httptest.NewRecorder()
		s.ServeHTTP(response, request)
		if response.Code != 400 {
			t.Fatalf("invalid forwarded proto accepted: %v, status %d", values, response.Code)
		}
	}
	for _, path := range []string{"/v1/session", "/v1/sync", "/v1/snapshot", "/v1/events", "/metrics"} {
		request := httptest.NewRequest(http.MethodGet, "http://example.test"+path, nil)
		request.Header.Set("X-Forwarded-Proto", "https")
		response := httptest.NewRecorder()
		s.ServeHTTP(response, request)
		if response.Code != 401 && !(path == "/metrics" && response.Code == 404) {
			t.Fatalf("ingress transport skipped authorization for %s: %d", path, response.Code)
		}
	}
}

func TestContainerAppsHTTPProbeExemptionIsGETHealthOnly(t *testing.T) {
	t.Setenv("CONTAINER_APP_NAME", "test-app")
	t.Setenv("CONTAINER_APP_REVISION", "test-app--test")
	s := transportServer(t, ContainerAppsTLSMode)
	for _, path := range []string{"/healthz", "/readyz"} {
		request := httptest.NewRequest(http.MethodGet, "http://example.test"+path, nil)
		response := httptest.NewRecorder()
		s.ServeHTTP(response, request)
		if response.Code != 200 {
			t.Fatalf("ACA HTTP probe %s refused: %d", path, response.Code)
		}
		for _, method := range []string{http.MethodHead, http.MethodPost} {
			request := httptest.NewRequest(method, "http://example.test"+path, nil)
			response := httptest.NewRecorder()
			s.ServeHTTP(response, request)
			if response.Code != 400 {
				t.Fatalf("non-GET probe exemption accepted for %s", method)
			}
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if s.CheckReady(ctx) == nil {
		t.Fatal("cancelled readiness operation accepted")
	}
}
