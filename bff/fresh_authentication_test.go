package syncbff

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
)

func TestFreshAuthenticationEvidenceUsesProductionPairChecksWithoutGraph(t *testing.T) {
	f := newIdentityHTTPFixture(t)
	ctx := oidc.ClientContext(context.Background(), &http.Client{
		Timeout: 3 * time.Second, Transport: identityDiscoveryTransport{f.broker},
	})
	challenge := strings.Repeat("a", 64)
	access := f.broker.access(t, nil, 0)
	id := f.broker.id(t, challenge, nil, 0)
	if err := VerifyFreshBrokerAuthentication(ctx, f.handler.config, f.broker.signed.target.Callback,
		challenge, brokerTestObject, access, id); err != nil {
		t.Fatal("independent selected-customer proof rejected", err)
	}
	if f.broker.requests != 0 {
		t.Fatal("authentication-only evidence performed a Graph or ownership operation")
	}
	for _, test := range []struct {
		name     string
		access   map[string]any
		id       map[string]any
		selected string
		key      int
	}{
		{"wrong API scope", map[string]any{"scp": nil}, nil, brokerTestObject, 0},
		{"wrong API audience", map[string]any{"aud": brokerProofClient}, nil, brokerTestObject, 0},
		{"wrong API object", map[string]any{"oid": brokerTestOther}, nil, brokerTestObject, 0},
		{"wrong ID object", nil, map[string]any{"oid": brokerTestOther}, brokerTestObject, 0},
		{"unapproved customer", nil, nil, brokerTestOther, 0},
		{"wrong ID signature", nil, nil, brokerTestObject, 1},
		{"missing nonce", nil, map[string]any{"nonce": nil}, brokerTestObject, 0},
		{"wrong nonce", nil, map[string]any{"nonce": strings.Repeat("b", 64)}, brokerTestObject, 0},
		{"missing auth_time", nil, map[string]any{"auth_time": nil}, brokerTestObject, 0},
		{"string auth_time", nil, map[string]any{"auth_time": "1"}, brokerTestObject, 0},
		{"fractional auth_time", nil, map[string]any{"auth_time": float64(time.Now().Unix()) + 0.5}, brokerTestObject, 0},
		{"stale auth_time", nil, map[string]any{"auth_time": time.Now().Add(-10 * time.Minute).Unix()}, brokerTestObject, 0},
	} {
		t.Run(test.name, func(t *testing.T) {
			err := VerifyFreshBrokerAuthentication(ctx, f.handler.config, f.broker.signed.target.Callback,
				challenge, test.selected, f.broker.access(t, test.access, 0), f.broker.id(t, challenge, test.id, test.key))
			if err == nil || strings.Contains(err.Error(), brokerTestObject) {
				t.Fatal("invalid evidence accepted or private claim leaked")
			}
		})
	}
	if f.broker.requests != 0 {
		t.Fatal("rejected evidence requested a broker profile")
	}
}
