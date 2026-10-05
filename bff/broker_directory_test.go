package syncbff

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"golang.org/x/oauth2"
)

const (
	brokerTestTenant = "11111111-1111-4111-8111-111111111111"
	brokerTestClient = "22222222-2222-4222-8222-222222222222"
	brokerTestMI     = "33333333-3333-4333-8333-333333333333"
	brokerTestSource = "44444444-4444-4444-8444-444444444444"
	brokerTestObject = "55555555-5555-4555-8555-555555555555"
	brokerTestUser   = "66666666-6666-4666-8666-666666666666"
	brokerTestOther  = "77777777-7777-4777-8777-777777777777"
)

func brokerTestOptions() brokerDirectoryOptions {
	return brokerDirectoryOptions{
		TenantID: brokerTestTenant, InitialDomain: "fixture.onmicrosoft.com",
		ReaderClientID: brokerTestClient, ManagedIdentityClientID: brokerTestMI,
		WorkforceTenantIDs: []string{brokerTestSource},
	}
}

func brokerTestIssuer() string {
	return "https://login.microsoftonline.com/" + brokerTestSource + "/v2.0/" + brokerTestTenant
}

func brokerTestProfile() map[string]any {
	return map[string]any{
		"id": brokerTestObject, "accountEnabled": true,
		"identities": []map[string]any{
			{"signInType": "federated", "issuer": brokerTestIssuer(), "issuerAssignedId": brokerTestUser},
			{"signInType": "userPrincipalName", "issuer": "fixture.onmicrosoft.com", "issuerAssignedId": "generated-metadata@fixture.onmicrosoft.com"},
		},
	}
}

type brokerCredential struct {
	mu      sync.Mutex
	calls   int
	options policy.TokenRequestOptions
	token   azcore.AccessToken
	err     error
}

func (c *brokerCredential) GetToken(ctx context.Context, options policy.TokenRequestOptions) (azcore.AccessToken, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.calls++
	c.options = options
	return c.token, c.err
}

type brokerFixtureTransport struct {
	transport http.RoundTripper
	target    *url.URL
}

func (t brokerFixtureTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	if request.URL.Scheme != "https" || request.URL.Host != "graph.microsoft.com" ||
		request.Method != http.MethodGet || request.URL.Path != "/v1.0/users/"+brokerTestObject ||
		request.URL.RawQuery != "$select=id,accountEnabled,identities" {
		return nil, errors.New("unexpected broker network destination")
	}
	copy := request.Clone(request.Context())
	copy.URL.Scheme, copy.URL.Host = t.target.Scheme, t.target.Host
	return t.transport.RoundTrip(copy)
}

type brokerFactoryTransport struct {
	transport http.RoundTripper
	target    *url.URL
}

func (t brokerFactoryTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	if request.URL.Scheme != "https" ||
		(request.URL.Host != t.target.Host && request.URL.Host != "login.microsoftonline.com" &&
			request.URL.Host != "login.microsoft.com" && request.URL.Host != "graph.microsoft.com") {
		return nil, errors.New("unexpected workload credential authority")
	}
	copy := request.Clone(request.Context())
	copy.Header.Set("X-Fixture-Original-Host", request.URL.Host)
	copy.URL.Scheme, copy.URL.Host = t.target.Scheme, t.target.Host
	return t.transport.RoundTrip(copy)
}

func TestBrokerDirectoryFactoryUsesOnlyPinnedManagedIdentityAssertionExchange(t *testing.T) {
	managedCalls, exchangeCalls, graphCalls := 0, 0, 0
	authority := "https://login.microsoftonline.com/" + brokerTestTenant
	write := func(w http.ResponseWriter, value any) {
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(value); err != nil {
			t.Error(err)
		}
	}
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Cookie") != "" {
			t.Error("workload credential request contained browser cookies")
		}
		host := r.Header.Get("X-Fixture-Original-Host")
		switch r.URL.Path {
		case "/mi":
			managedCalls++
			if r.Method != http.MethodGet || r.URL.Query().Get("resource") != "api://AzureADTokenExchange" ||
				r.URL.Query().Get("client_id") != brokerTestMI || r.Header.Get("X-IDENTITY-HEADER") != "fixture-managed-identity-header" {
				t.Error("managed-identity assertion did not pin its client and token-exchange resource")
			}
			write(w, map[string]any{
				"access_token": "fixture-managed-identity-assertion",
				"expires_on":   fmt.Sprint(time.Now().Add(time.Hour).Unix()),
				"token_type":   "Bearer", "resource": "api://AzureADTokenExchange",
			})
		case "/common/discovery/instance":
			if host != "login.microsoftonline.com" && host != "login.microsoft.com" {
				t.Error("instance discovery escaped the pinned public cloud")
			}
			write(w, map[string]any{
				"tenant_discovery_endpoint": authority + "/v2.0/.well-known/openid-configuration",
				"metadata": []map[string]any{{
					"preferred_network": "login.microsoftonline.com", "preferred_cache": "login.microsoftonline.com",
					"aliases": []string{"login.microsoftonline.com", "login.microsoft.com", "login.windows.net", "sts.windows.net"},
				}},
			})
		case "/" + brokerTestTenant + "/v2.0/.well-known/openid-configuration":
			if host != "login.microsoftonline.com" {
				t.Error("token discovery did not use the exact pinned tenant authority")
			}
			write(w, map[string]any{
				"issuer":                 authority + "/v2.0",
				"authorization_endpoint": authority + "/oauth2/v2.0/authorize",
				"token_endpoint":         authority + "/oauth2/v2.0/token",
				"jwks_uri":               "https://login.microsoftonline.com/common/discovery/v2.0/keys",
			})
		case "/" + brokerTestTenant + "/oauth2/v2.0/token":
			exchangeCalls++
			if r.ParseForm() != nil {
				t.Error("invalid synthetic assertion-exchange form")
				http.Error(w, "invalid fixture form", http.StatusBadRequest)
				return
			}
			scopes := strings.Fields(r.PostForm.Get("scope"))
			slices.Sort(scopes)
			// MSAL adds its standard OIDC scopes to the requested resource scope.
			expectedScopes := []string{"https://graph.microsoft.com/.default", "offline_access", "openid", "profile"}
			if r.Method != http.MethodPost || host != "login.microsoftonline.com" ||
				r.PostForm.Get("client_id") != brokerTestClient || r.PostForm.Get("grant_type") != "client_credentials" ||
				r.PostForm.Get("client_assertion") != "fixture-managed-identity-assertion" ||
				r.PostForm.Get("client_assertion_type") != "urn:ietf:params:oauth:client-assertion-type:jwt-bearer" ||
				!slices.Equal(scopes, expectedScopes) ||
				r.PostForm.Get("client_secret") != "" {
				t.Error("cross-tenant Graph exchange did not use the exact secret-free assertion contract")
			}
			write(w, map[string]any{"access_token": "fixture-exchanged-graph-token", "token_type": "Bearer", "expires_in": 3600})
		case "/v1.0/users/" + brokerTestObject:
			graphCalls++
			if r.Method != http.MethodGet || host != "graph.microsoft.com" ||
				r.Header.Get("Authorization") != "Bearer fixture-exchanged-graph-token" ||
				r.URL.RawQuery != "$select=id,accountEnabled,identities" {
				t.Error("profile read did not use only the exchanged Graph credential and exact object")
			}
			write(w, brokerTestProfile())
		default:
			t.Error("unexpected workload credential endpoint")
			http.Error(w, "unexpected fixture request", http.StatusBadRequest)
		}
	}))
	t.Cleanup(server.Close)
	target, _ := url.Parse(server.URL)
	client := server.Client()
	client.Transport = brokerFactoryTransport{client.Transport, target}
	t.Setenv("IDENTITY_ENDPOINT", server.URL+"/mi")
	t.Setenv("IDENTITY_HEADER", "fixture-managed-identity-header")
	t.Setenv("IMDS_ENDPOINT", "")
	t.Setenv("AZURE_AUTHORITY_HOST", "https://attacker.invalid")
	t.Setenv("AZURE_CLIENT_SECRET", "fixture-secret-must-not-be-used")
	t.Setenv("AZURE_CLIENT_ID", brokerTestOther)
	ctx := context.WithValue(context.Background(), oauth2.HTTPClient, client)
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	reader, err := newBrokerDirectoryReader(ctx, brokerTestOptions())
	if err != nil {
		t.Fatal(err)
	}
	for range 2 {
		got, err := reader.lookup(ctx, brokerTestObject)
		if err != nil || got.Subject != brokerTestUser {
			t.Fatalf("actual SDK assertion/exchange fixture failed: %v", err)
		}
	}
	if managedCalls != 1 || exchangeCalls != 1 || graphCalls != 2 {
		t.Fatalf("unexpected assertion/exchange/profile counts: %d/%d/%d", managedCalls, exchangeCalls, graphCalls)
	}
}

func brokerFixture(t *testing.T, handler http.HandlerFunc) (*brokerDirectoryReader, *brokerCredential) {
	t.Helper()
	server := httptest.NewTLSServer(handler)
	t.Cleanup(server.Close)
	target, _ := url.Parse(server.URL)
	client := server.Client()
	client.Transport = brokerFixtureTransport{client.Transport, target}
	credential := &brokerCredential{token: azcore.AccessToken{Token: "fixture-graph-credential", ExpiresOn: time.Now().Add(time.Hour)}}
	ctx := context.WithValue(context.Background(), oauth2.HTTPClient, client)
	reader, err := newBrokerDirectoryReaderWithCredential(ctx, brokerTestOptions(), credential)
	if err != nil {
		t.Fatal(err)
	}
	return reader, credential
}

func TestBrokerDirectoryReaderPinsConfiguration(t *testing.T) {
	if !validBrokerDirectoryOptions(brokerTestOptions()) {
		t.Fatal("valid private reader configuration rejected")
	}
	for name, change := range map[string]func(*brokerDirectoryOptions){
		"invalid tenant":        func(c *brokerDirectoryOptions) { c.TenantID = "common" },
		"invalid reader":        func(c *brokerDirectoryOptions) { c.ReaderClientID = "email@fixture.invalid" },
		"invalid MI":            func(c *brokerDirectoryOptions) { c.ManagedIdentityClientID = "" },
		"same reader and MI":    func(c *brokerDirectoryOptions) { c.ManagedIdentityClientID = c.ReaderClientID },
		"empty sources":         func(c *brokerDirectoryOptions) { c.WorkforceTenantIDs = nil },
		"duplicate sources":     func(c *brokerDirectoryOptions) { c.WorkforceTenantIDs = []string{brokerTestSource, brokerTestSource} },
		"same source as target": func(c *brokerDirectoryOptions) { c.WorkforceTenantIDs = []string{brokerTestTenant} },
		"invalid source":        func(c *brokerDirectoryOptions) { c.WorkforceTenantIDs = []string{"organizations"} },
		"empty domain":          func(c *brokerDirectoryOptions) { c.InitialDomain = "" },
		"domain suffix attack":  func(c *brokerDirectoryOptions) { c.InitialDomain = "fixture.onmicrosoft.com.attacker.invalid" },
		"domain port":           func(c *brokerDirectoryOptions) { c.InitialDomain = "fixture:443.onmicrosoft.com" },
		"domain leading dash":   func(c *brokerDirectoryOptions) { c.InitialDomain = "-fixture.onmicrosoft.com" },
		"domain trailing dash":  func(c *brokerDirectoryOptions) { c.InitialDomain = "fixture-.onmicrosoft.com" },
	} {
		t.Run(name, func(t *testing.T) {
			options := brokerTestOptions()
			change(&options)
			if validBrokerDirectoryOptions(options) {
				t.Fatal("unsafe reader configuration accepted")
			}
		})
	}
	if _, err := newBrokerDirectoryReaderWithCredential(context.Background(), brokerTestOptions(), nil); err == nil {
		t.Fatal("missing server credential accepted")
	}
	options := brokerTestOptions()
	reader, err := newBrokerDirectoryReaderWithCredential(context.Background(), options, &brokerCredential{})
	if err != nil {
		t.Fatal(err)
	}
	options.WorkforceTenantIDs[0] = brokerTestOther
	if reader.options.WorkforceTenantIDs[0] != brokerTestSource {
		t.Fatal("operator source configuration was not copied")
	}
}

func TestBrokerDirectoryReaderUsesOnlyExactBoundedPrivateLookup(t *testing.T) {
	requests := 0
	reader, credential := brokerFixture(t, func(w http.ResponseWriter, r *http.Request) {
		requests++
		if r.Header.Get("Authorization") != "Bearer fixture-graph-credential" || r.Header.Get("Cache-Control") != "no-store" ||
			r.Header.Get("Cookie") != "" || r.URL.Query().Get("$select") != "id,accountEnabled,identities" {
			t.Error("Graph lookup did not preserve its private least-data boundary")
		}
		_ = json.NewEncoder(w).Encode(brokerTestProfile())
	})
	got, err := reader.lookup(context.Background(), brokerTestObject)
	if err != nil {
		t.Fatal(err)
	}
	if got.ObjectID != brokerTestObject || got.Subject != brokerTestUser || got.Issuer != brokerTestIssuer() ||
		got.Fingerprint != namespacedID("broker-binding-v1", brokerTestTenant, brokerTestObject, brokerTestIssuer(), brokerTestUser) {
		t.Fatal("binding was not derived solely from the trusted directory response")
	}
	if credential.calls != 1 || !reflect.DeepEqual(credential.options.Scopes, []string{"https://graph.microsoft.com/.default"}) ||
		reader.client.Timeout > 10*time.Second || reader.client.Jar != nil {
		t.Fatal("credential scope or HTTPS bounds changed")
	}
	if _, err := reader.lookup(context.Background(), brokerTestObject); err != nil || requests != 2 {
		t.Fatal("directory result was cached instead of reverified online")
	}
	for _, invalid := range []string{"", "email@fixture.invalid", "../" + brokerTestObject, brokerTestObject + "?$select=mail"} {
		if _, err := reader.lookup(context.Background(), invalid); err == nil {
			t.Fatal("client-shaped lookup target accepted")
		}
	}
	if requests != 2 || credential.calls != 2 {
		t.Fatal("invalid object ID reached a credential/network operation")
	}
}

func TestBrokerDirectoryReaderRejectsChangedMissingAndAdministrativeCredentials(t *testing.T) {
	cases := map[string]func(map[string]any){
		"second federated credential": func(p map[string]any) {
			p["identities"] = append(p["identities"].([]map[string]any), map[string]any{
				"signInType": "federated", "issuer": brokerTestIssuer(), "issuerAssignedId": brokerTestOther,
			})
		},
		"unapproved issuer": func(p map[string]any) {
			p["identities"].([]map[string]any)[0]["issuer"] = "https://issuer.invalid/"
		},
		"email subject": func(p map[string]any) {
			p["identities"].([]map[string]any)[0]["issuerAssignedId"] = "same-email@fixture.invalid"
		},
		"admin namespace": func(p map[string]any) {
			p["identities"].([]map[string]any)[0]["signInType"] = "ExternalAzureAD"
		},
		"local email identity": func(p map[string]any) {
			p["identities"].([]map[string]any)[0]["signInType"] = "emailAddress"
		},
		"only generated UPN": func(p map[string]any) {
			p["identities"] = p["identities"].([]map[string]any)[1:]
		},
		"duplicate UPN": func(p map[string]any) {
			p["identities"] = append(p["identities"].([]map[string]any), p["identities"].([]map[string]any)[1])
		},
		"foreign UPN metadata": func(p map[string]any) {
			p["identities"].([]map[string]any)[1]["issuer"] = "other.onmicrosoft.com"
		},
		"disabled user":   func(p map[string]any) { p["accountEnabled"] = false },
		"missing enabled": func(p map[string]any) { delete(p, "accountEnabled") },
		"wrong object":    func(p map[string]any) { p["id"] = brokerTestOther },
		"null identities": func(p map[string]any) { p["identities"] = nil },
	}
	for name, change := range cases {
		t.Run(name, func(t *testing.T) {
			profile := brokerTestProfile()
			change(profile)
			reader, _ := brokerFixture(t, func(w http.ResponseWriter, r *http.Request) {
				_ = json.NewEncoder(w).Encode(profile)
			})
			got, err := reader.lookup(context.Background(), brokerTestObject)
			if err == nil || got.Subject != "" || got.Fingerprint != "" {
				t.Fatal("changed/invalid broker profile supplied a trusted binding")
			}
			for _, private := range []string{brokerTestObject, brokerTestUser, "same-email", "fixture-graph-credential", "issuer.invalid"} {
				if strings.Contains(err.Error(), private) {
					t.Fatal("directory denial leaked private identity/credential details")
				}
			}
		})
	}
}

func TestBrokerDirectoryReaderReportsTransportPermissionAndMetadataFailures(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status int
		body   string
	}{
		{"missing user", 404, `{"error":{"message":"private-profile-detail"}}`},
		{"missing graph permission", 403, `{"error":{"message":"private-profile-detail"}}`},
		{"redirect", 302, ""},
		{"malformed json", 200, `{"id":`},
		{"duplicate enabled property", 200, `{"id":"` + brokerTestObject + `","accountEnabled":true,"accountEnabled":false,"identities":[]}`},
		{"oversized json", 200, `{"padding":"` + strings.Repeat("a", maxBrokerProfileBytes) + `"}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			received := 0
			reader, _ := brokerFixture(t, func(w http.ResponseWriter, r *http.Request) {
				received++
				if tc.status == 302 {
					w.Header().Set("Location", "https://attacker.invalid/collect")
				}

				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			})
			got, err := reader.lookup(context.Background(), brokerTestObject)
			if err == nil || got.Subject != "" || strings.Contains(err.Error(), "private-profile") || received != 1 {
				t.Fatal("invalid upstream response was accepted, reflected or redirected")
			}
		})
	}
	reader, credential := brokerFixture(t, func(w http.ResponseWriter, r *http.Request) { t.Error("invalid credential reached Graph") })
	for _, token := range []azcore.AccessToken{
		{}, {Token: "expired-secret", ExpiresOn: time.Now().Add(-time.Minute)},
		{Token: "unsafe\nsecret", ExpiresOn: time.Now().Add(time.Hour)},
	} {
		credential.token = token
		if _, err := reader.lookup(context.Background(), brokerTestObject); err == nil || strings.Contains(err.Error(), "secret") {
			t.Fatal("invalid server credential was accepted or exposed")
		}
	}
	credential.err = errors.New("raw-server-secret")
	if _, err := reader.lookup(context.Background(), brokerTestObject); err == nil || strings.Contains(err.Error(), "secret") {
		t.Fatal("credential failure was not redacted")
	}
}

func TestBrokerDirectoryReaderDetectsSingleCredentialReplacementWithoutAdoption(t *testing.T) {
	profile := brokerTestProfile()
	requests := 0
	reader, _ := brokerFixture(t, func(w http.ResponseWriter, r *http.Request) {
		requests++
		_ = json.NewEncoder(w).Encode(profile)
	})
	original, err := reader.lookup(context.Background(), brokerTestObject)
	if err != nil {
		t.Fatal(err)
	}
	if err := reader.reverify(context.Background(), original); err != nil {
		t.Fatal(err)
	}
	profile["identities"].([]map[string]any)[0]["issuerAssignedId"] = brokerTestOther
	if err := reader.reverify(context.Background(), original); err == nil {
		t.Fatal("out-of-band single-credential replacement adopted the old broker account")
	}
	if requests != 3 || original.Subject != brokerTestUser {
		t.Fatal("existing binding mutated or extra lookup performed")
	}
	corrupt := original
	corrupt.Fingerprint = strings.Repeat("0", 64)
	if err := reader.reverify(context.Background(), corrupt); err == nil || requests != 3 {
		t.Fatal("corrupt recorded binding reached a credential or Graph lookup")
	}
}
