package syncbff

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/coreos/go-oidc/v3/oidc"
	"golang.org/x/oauth2"
)

const brokerProofClient = "88888888-8888-4888-8888-888888888888"
const brokerProofAPI = "99999999-9999-4999-8999-999999999999"
const brokerProofSecondUser = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
const brokerProofThirdObject = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

type brokerProofFixture struct {
	signed   *directoryProofFixture
	reader   *brokerDirectoryReader
	verifier *brokerProofVerifier
	profile  map[string]any
	profiles map[string]map[string]any
	requests int
}

func newBrokerProofFixture(t *testing.T) *brokerProofFixture {
	t.Helper()
	f := &brokerProofFixture{signed: newDirectoryProofFixture(t), profile: brokerTestProfile()}
	f.signed.target.Issuer, f.signed.target.ClientID = brokerIssuer(brokerTestTenant), brokerProofClient
	ctx := oidc.ClientContext(context.Background(), f.signed.server.Client())
	var err error
	f.signed.verifier, err = newDirectoryProofVerifier(ctx, f.signed.target, f.signed.server.URL+"/jwks")
	if err != nil {
		t.Fatal(err)
	}
	f.signed.verifier.now = func() time.Time { return f.signed.now }
	apiConfig := OIDCConfig{
		Issuer: f.signed.target.Issuer, Audience: brokerProofAPI, TenantClaim: "tid",
		RequiredScope: "Cosmos.Sync", AllowedClientIDs: []string{brokerProofClient},
	}
	api := &Server{
		config: Config{OIDC: apiConfig},
		verifier: oidc.NewVerifier(apiConfig.Issuer, oidc.NewRemoteKeySet(ctx, f.signed.server.URL+"/jwks"),
			&oidc.Config{ClientID: apiConfig.Audience, SupportedSigningAlgs: []string{oidc.RS256}}),
	}
	f.profiles = map[string]map[string]any{brokerTestObject: f.profile}
	graph := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.requests++
		object := strings.TrimPrefix(r.URL.Path, "/v1.0/users/")
		profile, exists := f.profiles[object]
		if !exists {
			http.NotFound(w, r)
			return
		}
		if err := json.NewEncoder(w).Encode(profile); err != nil {
			t.Error(err)
		}
	}))
	t.Cleanup(graph.Close)
	location, _ := url.Parse(graph.URL)
	client := graph.Client()
	client.Transport = brokerProofTransport{client.Transport, location}
	credential := &brokerCredential{token: azcore.AccessToken{Token: "fixture-graph-credential", ExpiresOn: time.Now().Add(time.Hour)}}
	f.reader, err = newBrokerDirectoryReaderWithCredential(context.WithValue(ctx, oauth2.HTTPClient, client), brokerTestOptions(), credential)
	if err != nil {
		t.Fatal(err)
	}
	f.verifier, err = newBrokerProofVerifier(api, f.signed.verifier, f.reader)
	if err != nil {
		t.Fatal(err)
	}
	return f
}

type brokerProofTransport struct {
	transport http.RoundTripper
	target    *url.URL
}

func (t brokerProofTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	object := strings.TrimPrefix(request.URL.Path, "/v1.0/users/")
	if request.URL.Scheme != "https" || request.URL.Host != "graph.microsoft.com" || request.Method != http.MethodGet ||
		request.URL.Path != "/v1.0/users/"+object || !operationIDPattern.MatchString(object) ||
		request.URL.RawQuery != "$select=id,accountEnabled,identities" {
		return nil, errors.New("unexpected broker proof fixture destination")
	}
	copy := request.Clone(request.Context())
	copy.URL.Scheme, copy.URL.Host = t.target.Scheme, t.target.Host
	return t.transport.RoundTrip(copy)
}

func (f *brokerProofFixture) access(t *testing.T, changes map[string]any, key int) string {
	t.Helper()
	claims := map[string]any{
		"aud": brokerProofAPI, "sub": "api-specific-subject", "nonce": nil, "auth_time": nil,
		"scp": "Cosmos.Sync", "oid": brokerTestObject, "tid": brokerTestTenant,
		"azp": brokerProofClient, "ver": "2.0",
	}
	for name, value := range changes {
		claims[name] = value
	}
	return f.signed.token(t, "", claims, nil, key)
}

func (f *brokerProofFixture) id(t *testing.T, challenge string, changes map[string]any, key int) string {
	t.Helper()
	claims := map[string]any{
		"sub": "native-specific-subject", "oid": brokerTestObject, "tid": brokerTestTenant, "ver": "2.0",
	}
	for name, value := range changes {
		claims[name] = value
	}
	return f.signed.token(t, challenge, claims, nil, key)
}

func TestBrokerProofCorrelatesSignedObjectsNotSubjectsOrEmail(t *testing.T) {
	f := newBrokerProofFixture(t)
	challenge := strings.Repeat("a", 64)
	access := f.access(t, map[string]any{"email": "same-email@fixture.invalid"}, 0)
	id := f.id(t, challenge, map[string]any{"email": "other-email@fixture.invalid"}, 0)
	proof, err := f.verifier.verify(context.Background(), access, id, challenge)
	if err != nil || !validBrokerDirectoryProof(proof) || f.requests != 1 ||
		proof.Subject != brokerIdentitySubject(proof.BrokerBinding) || proof.BrokerBinding.Subject != brokerTestUser ||
		proof.Subject == "api-specific-subject" || proof.Subject == "native-specific-subject" {
		t.Fatal("independent signed subjects were not correlated only by oid/tid and fresh trusted binding", err)
	}
	if _, err := f.verifier.verify(context.Background(), access, id, challenge); err != nil || f.requests != 2 {
		t.Fatal("fresh broker proof profile was cached", err)
	}
}

func TestBrokerProofRejectsAPIAndIDCorrelationAttacksBeforeGraph(t *testing.T) {
	f := newBrokerProofFixture(t)
	challenge := strings.Repeat("a", 64)
	for _, test := range []struct {
		name   string
		access map[string]any
		id     map[string]any
	}{
		{"ID audience on API", map[string]any{"aud": brokerProofClient}, nil},
		{"missing API scope", map[string]any{"scp": nil}, nil},
		{"wrong API client", map[string]any{"azp": brokerTestOther}, nil},
		{"missing API client", map[string]any{"azp": nil}, nil},
		{"structured API client", map[string]any{"azp": []string{brokerProofClient}}, nil},
		{"foreign API tenant", map[string]any{"tid": brokerTestSource}, nil},
		{"missing API object", map[string]any{"oid": nil}, nil},
		{"structured API object", map[string]any{"oid": []string{brokerTestObject}}, nil},
		{"API email as object", map[string]any{"oid": "same-email@fixture.invalid"}, nil},
		{"API v1 claim", map[string]any{"ver": "1.0"}, nil},
		{"foreign signed ID object", nil, map[string]any{"oid": brokerTestOther}},
		{"missing signed ID object", nil, map[string]any{"oid": nil}},
		{"structured signed ID object", nil, map[string]any{"oid": []string{brokerTestObject}}},
		{"foreign signed ID tenant", nil, map[string]any{"tid": brokerTestSource}},
		{"missing signed ID tenant", nil, map[string]any{"tid": nil}},
		{"ID v1 claim", nil, map[string]any{"ver": "1.0"}},
		{"missing ID version", nil, map[string]any{"ver": nil}},
		{"refresh instead of reauth", nil, map[string]any{"auth_time": f.signed.now.Add(-identityChallengeLifetime).Unix()}},
		{"wrong signed challenge", nil, map[string]any{"nonce": strings.Repeat("b", 64)}},
		{"equal subjects cannot repair OID", map[string]any{"sub": "equal-subject"}, map[string]any{"sub": "equal-subject", "oid": brokerTestOther}},
		{"equal emails cannot repair OID", map[string]any{"email": "equal@fixture.invalid"}, map[string]any{"email": "equal@fixture.invalid", "oid": brokerTestOther}},
	} {
		t.Run(test.name, func(t *testing.T) {
			proof, err := f.verifier.verify(context.Background(), f.access(t, test.access, 0), f.id(t, challenge, test.id, 0), challenge)
			if err == nil || proof != (verifiedDirectoryProof{}) || f.requests != 0 {
				t.Fatal("untrusted/uncorrelated claims supplied a proof or reached Graph")
			}
			for _, private := range []string{brokerTestObject, brokerTestSource, "same-email", "equal@"} {
				if strings.Contains(err.Error(), private) {
					t.Fatal("proof failure leaked private credential/identity details")
				}
			}
		})
	}
	for _, bad := range []struct{ access, id string }{
		{f.signed.token(t, "", map[string]any{"aud": brokerProofAPI, "scp": "Cosmos.Sync", "tid": brokerTestTenant, "oid": brokerTestObject, "azp": brokerProofClient, "ver": "2.0"}, map[string]any{"kid": f.signed.keyID(0)}, 1), f.id(t, challenge, nil, 0)},
		{f.access(t, nil, 0), f.signed.token(t, challenge, map[string]any{"tid": brokerTestTenant, "oid": brokerTestObject, "ver": "2.0"}, map[string]any{"kid": f.signed.keyID(0)}, 1)},
		{"", f.id(t, challenge, nil, 0)},
		{strings.Repeat("x", 32769), f.id(t, challenge, nil, 0)},
	} {
		if proof, err := f.verifier.verify(context.Background(), bad.access, bad.id, challenge); err == nil || proof != (verifiedDirectoryProof{}) || f.requests != 0 {
			t.Fatal("forged/missing/oversized credential reached the trusted profile reader")
		}
	}
}

func TestBrokerProofRejectsUnapprovedFactoryConfiguration(t *testing.T) {
	f := newBrokerProofFixture(t)
	for _, test := range []struct {
		name   string
		change func(*OIDCConfig, *identityProofTarget)
	}{
		{"foreign API issuer", func(c *OIDCConfig, _ *identityProofTarget) { c.Issuer = brokerIssuer(brokerTestSource) }},
		{"non-tenant claim", func(c *OIDCConfig, _ *identityProofTarget) { c.TenantClaim = "email" }},
		{"missing API scope", func(c *OIDCConfig, _ *identityProofTarget) { c.RequiredScope = "" }},
		{"client ID API audience", func(c *OIDCConfig, _ *identityProofTarget) { c.Audience = brokerProofClient }},
		{"missing client admission", func(c *OIDCConfig, _ *identityProofTarget) { c.AllowedClientIDs = nil }},
		{"extra API client", func(c *OIDCConfig, _ *identityProofTarget) {
			c.AllowedClientIDs = []string{brokerProofClient, brokerTestOther}
		}},
		{"foreign proof issuer", func(_ *OIDCConfig, target *identityProofTarget) { target.Issuer = brokerIssuer(brokerTestSource) }},
		{"unapproved provider", func(_ *OIDCConfig, target *identityProofTarget) { target.Provider = "google" }},
	} {
		t.Run(test.name, func(t *testing.T) {
			api, idProof := *f.verifier.api, *f.signed.verifier
			test.change(&api.config.OIDC, &idProof.target)
			_, err := newBrokerProofVerifier(&api, &idProof, f.reader)
			requireAuthorizationCode(t, err, "invalid_identity_configuration")
		})
	}
	for _, args := range []struct {
		api    *Server
		proof  *directoryProofVerifier
		reader *brokerDirectoryReader
	}{
		{nil, f.signed.verifier, f.reader}, {f.verifier.api, nil, f.reader}, {f.verifier.api, f.signed.verifier, nil},
	} {
		_, err := newBrokerProofVerifier(args.api, args.proof, args.reader)
		requireAuthorizationCode(t, err, "invalid_identity_configuration")
	}
}

func TestBrokerDirectoryRequiresAndAtomicallyRetainsExpectedFingerprint(t *testing.T) {
	f := newBrokerProofFixture(t)
	store := &testIdentityDirectoryStore{}
	d, err := newBrokerIdentityDirectory(store, []identityProofTarget{f.signed.target})
	if err != nil {
		t.Fatal(err)
	}
	d.now = func() time.Time { return f.signed.now }
	ctx := context.Background()
	raw, err := d.begin(ctx, nil, "register", f.signed.target, "")
	if err != nil {
		t.Fatal(err)
	}
	id := f.id(t, raw, nil, 0)
	generic, err := f.signed.verifier.verify(ctx, id, raw)
	if err != nil {
		t.Fatal(err)
	}
	_, err = d.register(ctx, raw, generic)
	requireAuthorizationCode(t, err, "identity_fresh_proof_required")
	if store.state.Challenges[generic.ChallengeDigest].Consumed || len(store.state.Bindings) != 0 {
		t.Fatal("missing broker proof partially consumed registration")
	}
	proof, err := f.verifier.verify(ctx, f.access(t, nil, 0), id, raw)
	if err != nil {
		t.Fatal(err)
	}
	account, err := d.register(ctx, raw, proof)
	if err != nil {
		t.Fatal(err)
	}
	binding := store.state.Bindings[account.IdentityIDs[0]]
	if binding.Broker == nil || *binding.Broker != proof.BrokerBinding || !validIdentityDirectory(store.state) {
		t.Fatal("fresh expected fingerprint was not persisted with nonce/replay/audit/account")
	}
	before := cloneTestDirectory(store.state)
	raw, err = d.begin(ctx, nil, "register", f.signed.target, "")
	if err != nil {
		t.Fatal(err)
	}
	beforeReplacement := cloneTestDirectory(store.state)
	f.profile["identities"].([]map[string]any)[0]["issuerAssignedId"] = brokerTestOther
	replacement, err := f.verifier.verify(ctx, f.access(t, nil, 0), f.id(t, raw, map[string]any{"sub": "unchanged-native-subject"}, 0), raw)
	if err != nil {
		t.Fatal(err)
	}
	_, err = d.register(ctx, raw, replacement)
	requireAuthorizationCode(t, err, "identity_binding_changed")
	if !reflect.DeepEqual(beforeReplacement, store.state) || *store.state.Bindings[account.IdentityIDs[0]].Broker != proof.BrokerBinding ||
		!reflect.DeepEqual(before.Accounts, store.state.Accounts) {
		t.Fatal("same-broker-object replacement adopted ownership or partially committed")
	}
	store.state.Bindings[account.IdentityIDs[0]].Broker.Fingerprint = strings.Repeat("0", 64)
	if validIdentityDirectory(store.state) {
		t.Fatal("corrupted recorded fingerprint remained valid")
	}
}

func TestBrokerProofPropagatesTrustedProfileFailureWithoutProof(t *testing.T) {
	f := newBrokerProofFixture(t)
	f.profile["accountEnabled"] = false
	raw := strings.Repeat("a", 64)
	proof, err := f.verifier.verify(context.Background(), f.access(t, nil, 0), f.id(t, raw, nil, 0), raw)
	requireAuthorizationCode(t, err, "identity_binding_inactive")
	if proof != (verifiedDirectoryProof{}) || f.requests != 1 {
		t.Fatal("disabled profile supplied a proof")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = f.signed.verifier.verify(ctx, f.id(t, raw, nil, 0), raw)
	if !errors.Is(err, context.Canceled) {
		t.Fatal("signed-proof cancellation was hidden", err)
	}
}

func TestBrokerDirectorySignedLinkUnlinkAndTombstonePreserveFingerprints(t *testing.T) {
	f := newBrokerProofFixture(t)
	second := brokerTestProfile()
	second["id"] = brokerTestOther
	second["identities"].([]map[string]any)[0]["issuerAssignedId"] = brokerProofSecondUser
	f.profiles[brokerTestOther] = second
	third := brokerTestProfile()
	third["id"] = brokerProofThirdObject
	f.profiles[brokerProofThirdObject] = third
	store := &testIdentityDirectoryStore{}
	d, err := newBrokerIdentityDirectory(store, []identityProofTarget{f.signed.target})
	if err != nil {
		t.Fatal(err)
	}
	d.now = func() time.Time { return f.signed.now }
	ctx := context.Background()
	verify := func(raw, object string) verifiedDirectoryProof {
		t.Helper()
		proof, err := f.verifier.verify(ctx, f.access(t, map[string]any{"oid": object}, 0),
			f.id(t, raw, map[string]any{"oid": object, "sub": "native-subject-for-" + object}, 0), raw)
		if err != nil {
			t.Fatal(err)
		}
		return proof
	}
	begin := func(session *directorySession, operation, remove string) string {
		t.Helper()
		raw, err := d.begin(ctx, session, operation, f.signed.target, remove)
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	raw := begin(nil, "register", "")
	first := verify(raw, brokerTestObject)
	account, err := d.register(ctx, raw, first)
	if err != nil {
		t.Fatal(err)
	}
	resolved, resolvedSession, err := f.verifier.resolve(ctx, f.access(t, nil, 0), d)
	if err != nil || resolved.Account != account.Account || resolvedSession.AccountID != account.AccountID ||
		resolvedSession.IdentityID != account.IdentityIDs[0] || resolvedSession.Generation != 1 {
		t.Fatal("signed API identity could not resolve only its persisted random account", err)
	}
	session := directorySession{account.AccountID, account.Generation, account.IdentityIDs[0], f.signed.now.Add(time.Hour)}
	raw = begin(&session, "link", "")
	current, independent := verify(raw, brokerTestObject), verify(raw, brokerTestOther)
	before := cloneTestDirectory(store.state)
	substitute := verify(raw, brokerProofThirdObject)
	_, err = d.change(ctx, session, raw, "link", substitute, independent)
	requireAuthorizationCode(t, err, "identity_binding_changed")
	if !reflect.DeepEqual(before, store.state) {
		t.Fatal("recreated broker object adopted the original credential or consumed link")
	}
	linked, err := d.change(ctx, session, raw, "link", current, independent)
	if err != nil || linked.Account != account.Account || linked.Generation != 2 || len(linked.IdentityIDs) != 2 ||
		*store.state.Bindings[linked.IdentityIDs[1]].Broker != independent.BrokerBinding {
		t.Fatal("explicit signed link failed to retain both exact broker fingerprints", err)
	}
	resolved, resolvedSession, err = f.verifier.resolve(ctx, f.access(t, map[string]any{"oid": brokerTestOther}, 0), d)
	if err != nil || resolved.Account != account.Account || resolvedSession.Generation != linked.Generation {
		t.Fatal("explicitly linked signed API identity changed account ownership", err)
	}
	_, err = d.begin(ctx, &session, "link", f.signed.target, "")
	requireAuthorizationCode(t, err, "identity_session_invalid")
	session.Generation = linked.Generation
	raw = begin(&session, "unlink", linked.IdentityIDs[1])
	retained := verify(raw, brokerTestObject)
	unlinked, err := d.change(ctx, session, raw, "unlink", retained, retained)
	if err != nil || unlinked.Account != account.Account || unlinked.Generation != 3 ||
		store.state.Bindings[linked.IdentityIDs[1]].Active ||
		*store.state.Bindings[linked.IdentityIDs[1]].Broker != independent.BrokerBinding {
		t.Fatal("unlink discarded expected ownership/fingerprint tombstone", err)
	}
	_, _, err = f.verifier.resolve(ctx, f.access(t, map[string]any{"oid": brokerTestOther}, 0), d)
	requireAuthorizationCode(t, err, "identity_session_invalid")
	raw = begin(nil, "register", "")
	proof := verify(raw, brokerTestOther)
	before = cloneTestDirectory(store.state)
	_, err = d.register(ctx, raw, proof)
	requireAuthorizationCode(t, err, "identity_already_assigned")
	if !reflect.DeepEqual(before, store.state) {
		t.Fatal("unlinked broker credential was reassigned to another account")
	}
	session.Generation = unlinked.Generation
	raw = begin(&session, "link", "")
	current, independent = verify(raw, brokerTestObject), verify(raw, brokerTestOther)
	relinked, err := d.change(ctx, session, raw, "link", current, independent)
	if err != nil || relinked.Account != account.Account || relinked.Generation != 4 || !validIdentityDirectory(store.state) {
		t.Fatal("original account could not relink its exact fingerprint with fresh signed proofs", err)
	}
	second["identities"].([]map[string]any)[0]["issuerAssignedId"] = brokerTestUser
	raw = begin(nil, "register", "")
	replacement := verify(raw, brokerTestOther)
	before = cloneTestDirectory(store.state)
	_, err = d.register(ctx, raw, replacement)
	requireAuthorizationCode(t, err, "identity_binding_changed")
	if !reflect.DeepEqual(before, store.state) || len(store.state.Accounts) != 1 {
		t.Fatal("replaced broker profile silently created/adopted another account")
	}
	_, _, err = f.verifier.resolve(ctx, f.access(t, map[string]any{"oid": brokerTestOther}, 0), d)
	requireAuthorizationCode(t, err, "identity_binding_changed")
	_, _, err = f.verifier.resolve(ctx, f.access(t, map[string]any{"oid": brokerProofThirdObject}, 0), d)
	requireAuthorizationCode(t, err, "identity_binding_changed")
}

func TestBrokerResolutionDoesNotRegisterOrAdoptChangedMetadata(t *testing.T) {
	f := newBrokerProofFixture(t)
	store := &testIdentityDirectoryStore{}
	d, err := newBrokerIdentityDirectory(store, []identityProofTarget{f.signed.target})
	if err != nil {
		t.Fatal(err)
	}
	d.now = func() time.Time { return f.signed.now }
	ctx := context.Background()
	access := f.access(t, nil, 0)
	_, _, err = f.verifier.resolve(ctx, access, d)
	requireAuthorizationCode(t, err, "identity_registration_required")
	if store.writes != 0 || store.state != nil {
		t.Fatal("ordinary API authentication implicitly registered an account")
	}
	raw, err := d.begin(ctx, nil, "register", f.signed.target, "")
	if err != nil {
		t.Fatal(err)
	}
	proof, err := f.verifier.verify(ctx, access, f.id(t, raw, nil, 0), raw)
	if err != nil {
		t.Fatal(err)
	}
	account, err := d.register(ctx, raw, proof)
	if err != nil {
		t.Fatal(err)
	}
	before, writes, requests := cloneTestDirectory(store.state), store.writes, f.requests
	for range 2 {
		resolved, session, err := f.verifier.resolve(ctx, access, d)
		if err != nil || resolved.Account != account.Account || session.Generation != account.Generation {
			t.Fatal("trusted stored binding could not resolve its exact account", err)
		}
	}
	if f.requests != requests+2 || store.writes != writes || !reflect.DeepEqual(before, store.state) {
		t.Fatal("ordinary account lookup cached Graph results or mutated ownership/nonce/audit")
	}
	for _, test := range []struct {
		name   string
		change func(*identityDirectoryState)
		code   string
	}{
		{"missing fingerprint", func(state *identityDirectoryState) {
			binding := state.Bindings[account.IdentityIDs[0]]
			binding.Broker = nil
			state.Bindings[account.IdentityIDs[0]] = binding
		}, "identity_binding_changed"},
		{"corrupt fingerprint", func(state *identityDirectoryState) {
			state.Bindings[account.IdentityIDs[0]].Broker.Fingerprint = strings.Repeat("0", 64)
		}, "identity_directory_unavailable"},
		{"corrupt generation", func(state *identityDirectoryState) {
			record := state.Accounts[account.AccountID]
			record.Generation = 0
			state.Accounts[account.AccountID] = record
		}, "identity_directory_unavailable"},
	} {
		t.Run(test.name, func(t *testing.T) {
			store.state = cloneTestDirectory(before)
			test.change(store.state)
			damaged := cloneTestDirectory(store.state)
			resolved, session, err := f.verifier.resolve(ctx, access, d)
			requireAuthorizationCode(t, err, test.code)
			if resolved.AccountID != "" || session != (directorySession{}) || store.writes != writes || !reflect.DeepEqual(damaged, store.state) {
				t.Fatal("failed account lookup returned authority or repaired/adopted damaged metadata")
			}
		})
	}
	store.state = cloneTestDirectory(before)
	for _, candidate := range []*identityDirectory{nil, {store: store, targets: d.targets}} {
		requests = f.requests
		_, _, err = f.verifier.resolve(ctx, access, candidate)
		requireAuthorizationCode(t, err, "identity_directory_unavailable")
		if f.requests != requests {
			t.Fatal("unapproved directory construction reached Graph")
		}
	}
	f.profile["accountEnabled"] = false
	_, _, err = f.verifier.resolve(ctx, access, d)
	requireAuthorizationCode(t, err, "identity_binding_inactive")
	if store.writes != writes || !reflect.DeepEqual(before, store.state) {
		t.Fatal("disabled broker profile altered stored ownership")
	}
}

func TestBrokerDirectoryRejectsDuplicateBrokerOwnershipIncludingTombstones(t *testing.T) {
	f := newBrokerProofFixture(t)
	store := &testIdentityDirectoryStore{}
	d, err := newBrokerIdentityDirectory(store, []identityProofTarget{f.signed.target})
	if err != nil {
		t.Fatal(err)
	}
	d.now = func() time.Time { return f.signed.now }
	ctx := context.Background()
	raw, err := d.begin(ctx, nil, "register", f.signed.target, "")
	if err != nil {
		t.Fatal(err)
	}
	proof, err := f.verifier.verify(ctx, f.access(t, nil, 0), f.id(t, raw, nil, 0), raw)
	if err != nil {
		t.Fatal(err)
	}
	account, err := d.register(ctx, raw, proof)
	if err != nil {
		t.Fatal(err)
	}
	other := proof.BrokerBinding
	other.Subject = brokerTestOther
	other.Fingerprint = namespacedID("broker-binding-v1", brokerTestTenant, other.ObjectID, other.Issuer, other.Subject)
	identity := proof.identity()
	identity.Subject = brokerIdentitySubject(other)
	if !validRecordedBrokerBinding(identity, other) {
		t.Fatal("duplicate ownership fixture failed its independent binding checks")
	}
	for _, active := range []bool{false, true} {
		state := cloneTestDirectory(store.state)
		state.Bindings[identity.id()] = directoryBinding{AccountID: account.AccountID, Identity: identity, Active: active, Broker: &other}
		if active {
			record := state.Accounts[account.AccountID]
			record.IdentityIDs = append(record.IdentityIDs, identity.id())
			state.Accounts[account.AccountID] = record
		}
		if validIdentityDirectory(state) {
			t.Fatal("one broker object was validly assigned under two upstream keys")
		}
		replacement := other
		replacement.ObjectID = brokerProofThirdObject
		replacement.Fingerprint = namespacedID("broker-binding-v1", brokerTestTenant, replacement.ObjectID, replacement.Issuer, replacement.Subject)
		record := state.Bindings[identity.id()]
		record.Broker = &replacement
		state.Bindings[identity.id()] = record
		if !validIdentityDirectory(state) {
			t.Fatal("distinct broker objects were incorrectly considered duplicates")
		}
	}
}
