package syncbff

import (
	"context"
	"net/http"
	"strings"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
)

type IdentityDirectoryOptions struct {
	TenantID                string   `json:"tenantId"`
	InitialDomain           string   `json:"initialDomain"`
	ReaderClientID          string   `json:"readerClientId"`
	ManagedIdentityClientID string   `json:"managedIdentityClientId"`
	WorkforceTenantIDs      []string `json:"workforceTenantIds"`
	Namespace               string   `json:"namespace"`
	Callbacks               []string `json:"callbacks"`
}

type identityRuntime struct {
	directory     *identityDirectory
	authorization directoryAuthorizationStore
	proofs        map[string]*brokerProofVerifier
	resolver      *brokerProofVerifier
}

func (options *IdentityDirectoryOptions) readerOptions() brokerDirectoryOptions {
	return brokerDirectoryOptions{options.TenantID, options.InitialDomain, options.ReaderClientID,
		options.ManagedIdentityClientID, options.WorkforceTenantIDs}
}

func newIdentityRuntime(ctx context.Context, server *Server, options *IdentityDirectoryOptions) (*identityRuntime, error) {
	if options == nil || !validBrokerDirectoryOptions(options.readerOptions()) || !validIdentityText(options.Namespace, 128) ||
		len(options.Callbacks) == 0 || len(options.Callbacks) > 16 ||
		server.config.OIDC.Issuer != brokerIssuer(options.TenantID) || server.config.OIDC.TenantClaim != "tid" ||
		len(server.config.OIDC.AllowedClientIDs) != 1 {
		return nil, protocolError(400, "invalid_identity_configuration")
	}
	authorization, ok := server.store.(directoryAuthorizationStore)
	if !ok {
		return nil, protocolError(400, "invalid_identity_configuration")
	}
	var store identityDirectoryStore
	switch configured := server.store.(type) {
	case *CosmosStore:
		store = cosmosIdentityDirectoryStore{configured}
	case *MemoryStore:
		if !server.config.Development {
			return nil, protocolError(400, "invalid_identity_configuration")
		}
		store = memoryIdentityDirectoryStore{configured}
	default:
		return nil, protocolError(400, "invalid_identity_configuration")
	}
	clientID := server.config.OIDC.AllowedClientIDs[0]
	targets := make([]identityProofTarget, 0, len(options.Callbacks))
	seen := make(map[string]bool)
	for _, callback := range options.Callbacks {
		target := identityProofTarget{server.config.OIDC.Issuer, "entra", options.Namespace, clientID, callback}
		if !validIdentityTarget(target) || seen[callback] || !operationIDPattern.MatchString(clientID) ||
			clientID != strings.ToLower(clientID) || !operationIDPattern.MatchString(server.config.OIDC.Audience) ||
			server.config.OIDC.Audience != strings.ToLower(server.config.OIDC.Audience) || clientID == server.config.OIDC.Audience {
			return nil, protocolError(400, "invalid_identity_configuration")
		}
		seen[callback] = true
		targets = append(targets, target)
	}
	directory, err := newBrokerIdentityDirectory(store, targets)
	if err != nil {
		return nil, err
	}
	reader, err := newBrokerDirectoryReader(ctx, options.readerOptions())
	if err != nil {
		return nil, err
	}
	ctx = oidc.ClientContext(ctx, brokerHTTPClient(ctx))
	provider, err := oidc.NewProvider(ctx, server.config.OIDC.Issuer)
	if err != nil {
		return nil, protocolError(503, "identity_binding_unavailable")
	}
	var metadata struct {
		Keys string `json:"jwks_uri"`
	}
	if provider.Claims(&metadata) != nil {
		return nil, protocolError(503, "identity_binding_unavailable")
	}
	result := &identityRuntime{directory: directory, authorization: authorization, proofs: make(map[string]*brokerProofVerifier)}
	for _, target := range targets {
		proof, err := newDirectoryProofVerifier(ctx, target, metadata.Keys)
		if err != nil {
			return nil, err
		}
		broker, err := newBrokerProofVerifier(server, proof, reader)
		if err != nil {
			return nil, err
		}
		result.proofs[target.Callback] = broker
		if result.resolver == nil {
			result.resolver = broker
		}
	}
	return result, nil
}

func (runtime *identityRuntime) resolve(ctx context.Context, token string) (directoryAccount, directorySession, error) {
	return runtime.resolver.resolve(ctx, token, runtime.directory)
}

func checkDirectoryRequestBinding(request *http.Request, session directorySession) error {
	scope := Scope{IdentityGeneration: session.Generation, IdentityID: session.IdentityID}
	if err := checkIdentityRequestBinding(request, scope); err != nil {
		return err
	}
	principal := request.Header.Values(PrincipalHeader)
	if len(principal) != 1 || principal[0] != session.AccountID {
		return protocolError(401, "identity_session_invalid")
	}
	return nil
}

func (runtime *identityRuntime) proofForChallenge(ctx context.Context, raw, operation string) (*brokerProofVerifier, error) {
	digest, err := identityChallengeDigest(raw)
	if err != nil {
		return nil, err
	}
	state, _, err := runtime.directory.load(ctx)
	if err != nil {
		return nil, err
	}
	if state == nil {
		return nil, protocolError(409, "identity_challenge_invalid")
	}
	challenge, err := directoryChallengeFor(state, digest, operation, runtime.directory.now().UTC().Truncate(time.Second))
	if err != nil {
		return nil, err
	}
	proof := runtime.proofs[challenge.Target.Callback]
	if proof == nil || proof.idProof.target != challenge.Target {
		return nil, protocolError(401, "identity_fresh_proof_required")
	}
	return proof, nil
}
