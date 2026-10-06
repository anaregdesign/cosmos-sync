package syncbff

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestIdentityContextsBindGenerationAndCredentialWithoutChangingPolicyFence(t *testing.T) {
	server := &Server{key: []byte(strings.Repeat("k", 32)), config: Config{HistoryEpoch: "1"}}
	scope := Scope{ID: strings.Repeat("a", 64), PrincipalID: strings.Repeat("b", 64), PermissionVersion: "2",
		ScopeMode: "shared", CanRead: true, CanWrite: true, IdentityGeneration: 1, IdentityID: strings.Repeat("c", 64)}
	for _, purpose := range []string{"cursor-v1", "snapshot-v1", "events-v1", "session-v1"} {
		t.Run(purpose, func(t *testing.T) {
			value := server.boundContext(scope, 3)
			value.Token = "fixture-consistency-only"
			token := server.sign(purpose, value)
			verified, err := server.verifyContext(purpose, token, scope)
			if err != nil || verified.IdentityGeneration != 1 || verified.IdentityID != scope.IdentityID || verified.Permission != "2" {
				t.Fatal("context lost independent generation/credential/policy binding", err)
			}
			for _, change := range []func(*Scope){
				func(next *Scope) { next.IdentityGeneration = 2 },
				func(next *Scope) { next.IdentityID = strings.Repeat("d", 64) },
				func(next *Scope) { next.IdentityGeneration, next.IdentityID = 0, "" },
			} {
				next := scope
				change(&next)
				_, err := server.verifyContext(purpose, token, next)
				requireAuthorizationCode(t, err, "resync_required")
				if scope.sameBinding(next) {
					t.Fatal("generation/credential transition retained scope binding")
				}
			}
			legacy := scope
			legacy.IdentityGeneration, legacy.IdentityID = 0, ""
			legacyToken := server.sign(purpose, server.boundContext(legacy, 3))
			if _, err := server.verifyContext(purpose, legacyToken, legacy); err != nil {
				t.Fatal("legacy context compatibility changed", err)
			}
			_, err = server.verifyContext(purpose, legacyToken, scope)
			requireAuthorizationCode(t, err, "resync_required")
		})
	}
	policy := newAuthorizationPolicy(scope.ID, scope.PrincipalID, "shared")
	for _, generation := range []int64{1, maxIdentityGeneration} {
		owned, err := policy.scope(scope.PrincipalID)
		if err != nil {
			t.Fatal(err)
		}
		owned.IdentityGeneration, owned.IdentityID = generation, scope.IdentityID
		err = checkAuthorizationWrite(policy, scope.ID, Mutation{PrincipalID: owned.PrincipalID, AuthorizationVersion: owned.PermissionVersion})
		if err != nil || owned.PermissionVersion != "1" {
			t.Fatal("identity generation was composed into the numeric policy write fence", err)
		}
	}
}

func TestIdentityRequestBindingRejectsOldMissingAndAmbiguousAssertions(t *testing.T) {
	scope := Scope{IdentityGeneration: 1, IdentityID: strings.Repeat("a", 64)}
	request := func() *http.Request {
		r := httptest.NewRequest(http.MethodGet, "/v1/sync", nil)
		r.Header.Set(IdentityGenerationHeader, "1")
		r.Header.Set(IdentityHeader, scope.IdentityID)
		return r
	}
	if err := checkIdentityRequestBinding(request(), scope); err != nil {
		t.Fatal(err)
	}
	for _, change := range []func(*http.Request){
		func(r *http.Request) { r.Header.Del(IdentityGenerationHeader) },
		func(r *http.Request) { r.Header.Del(IdentityHeader) },
		func(r *http.Request) { r.Header.Set(IdentityGenerationHeader, "2") },
		func(r *http.Request) { r.Header.Set(IdentityGenerationHeader, "01") },
		func(r *http.Request) { r.Header.Set(IdentityGenerationHeader, "1.0") },
		func(r *http.Request) { r.Header.Set(IdentityHeader, strings.Repeat("b", 64)) },
		func(r *http.Request) { r.Header.Add(IdentityGenerationHeader, "1") },
		func(r *http.Request) { r.Header.Add(IdentityHeader, scope.IdentityID) },
	} {
		r := request()
		change(r)
		requireAuthorizationCode(t, checkIdentityRequestBinding(r, scope), "identity_session_invalid")
	}
	legacy := Scope{}
	if err := checkIdentityRequestBinding(httptest.NewRequest(http.MethodGet, "/v1/sync", nil), legacy); err != nil {
		t.Fatal("legacy request now requires identity headers", err)
	}
	requireAuthorizationCode(t, checkIdentityRequestBinding(request(), legacy), "identity_session_invalid")
	for _, damaged := range []Scope{
		{IdentityGeneration: 1}, {IdentityID: scope.IdentityID},
		{IdentityGeneration: maxIdentityGeneration + 1, IdentityID: scope.IdentityID},
		{IdentityGeneration: -1, IdentityID: scope.IdentityID},
		{IdentityGeneration: 1, IdentityID: "not-an-identity"},
	} {
		requireAuthorizationCode(t, checkIdentityRequestBinding(request(), damaged), "identity_directory_unavailable")
	}
}

func TestIdentityScopeRevalidationAndOptionalJSON(t *testing.T) {
	legacy := Scope{ID: strings.Repeat("a", 64), PrincipalID: strings.Repeat("b", 64), PermissionVersion: "1",
		ScopeMode: "user", CanRead: true, CanWrite: true}
	body, err := json.Marshal(legacy)
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(body, &fields) != nil || len(fields) != 4 {
		t.Fatal("legacy session JSON changed")
	}
	bound := legacy
	bound.IdentityGeneration, bound.IdentityID = maxIdentityGeneration, strings.Repeat("c", 64)
	if err := checkScopeBinding(bound, bound); err != nil {
		t.Fatal(err)
	}
	requireAuthorizationCode(t, checkScopeBinding(legacy, bound), "identity_session_invalid")
	changed := bound
	changed.IdentityGeneration--
	requireAuthorizationCode(t, checkScopeBinding(changed, bound), "identity_session_invalid")
	changed = bound
	changed.IdentityID = strings.Repeat("d", 64)
	requireAuthorizationCode(t, checkScopeBinding(changed, bound), "identity_session_invalid")
	changed = bound
	changed.CanRead = false
	requireAuthorizationCode(t, checkScopeBinding(changed, bound), "forbidden")
	body, err = json.Marshal(bound)
	if err != nil || json.Unmarshal(body, &fields) != nil || len(fields) != 6 ||
		string(fields["identityGeneration"]) != "10000" || string(fields["permissionVersion"]) != `"1"` {
		t.Fatal("identity binding was not serialized independently at its exact bound", err)
	}
}
