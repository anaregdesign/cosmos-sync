package syncbff

import (
	"context"
	"strings"

	"github.com/coreos/go-oidc/v3/oidc"
)

type brokerProofVerifier struct {
	api       *Server
	idProof   *directoryProofVerifier
	directory *brokerDirectoryReader
}

func brokerIssuer(tenant string) string {
	return "https://" + tenant + ".ciamlogin.com/" + tenant + "/v2.0"
}

func brokerTenant(issuer string) string {
	for _, part := range strings.Split(issuer, "/") {
		if operationIDPattern.MatchString(part) && part == strings.ToLower(part) && issuer == brokerIssuer(part) {
			return part
		}
	}
	return ""
}

func brokerIdentitySubject(binding verifiedBrokerBinding) string {
	return namespacedID("broker-source-v1", binding.Issuer, binding.Subject)
}

func directoryBrokerObjectID(identity directoryIdentity, objectID string) string {
	return namespacedID("directory-broker-object-v1", identity.Issuer, identity.Provider, identity.Namespace, identity.ClientID, objectID)
}

func validRecordedBrokerBinding(identity directoryIdentity, binding verifiedBrokerBinding) bool {
	tenant := brokerTenant(identity.Issuer)
	if tenant == "" || identity.Provider != "entra" ||
		!operationIDPattern.MatchString(identity.ClientID) || identity.ClientID != strings.ToLower(identity.ClientID) ||
		!operationIDPattern.MatchString(binding.ObjectID) || binding.ObjectID != strings.ToLower(binding.ObjectID) ||
		!operationIDPattern.MatchString(binding.Subject) || binding.Subject != strings.ToLower(binding.Subject) ||
		identity.Subject != brokerIdentitySubject(binding) {
		return false
	}
	source := strings.TrimPrefix(binding.Issuer, "https://login.microsoftonline.com/")
	source = strings.TrimSuffix(source, "/v2.0/"+tenant)
	return operationIDPattern.MatchString(source) && source != tenant && source == strings.ToLower(source) &&
		binding.Issuer == "https://login.microsoftonline.com/"+source+"/v2.0/"+tenant &&
		binding.Fingerprint == namespacedID("broker-binding-v1", tenant, binding.ObjectID, binding.Issuer, binding.Subject)
}

func validBrokerDirectoryProof(proof verifiedDirectoryProof) bool {
	return proof.BrokerTenantID == brokerTenant(proof.Target.Issuer) && proof.BrokerVersion == "2.0" &&
		proof.BrokerObjectID == proof.BrokerBinding.ObjectID && validRecordedBrokerBinding(proof.identity(), proof.BrokerBinding)
}

func newBrokerProofVerifier(api *Server, idProof *directoryProofVerifier, directory *brokerDirectoryReader) (*brokerProofVerifier, error) {
	if api == nil || api.verifier == nil || idProof == nil || idProof.verifier == nil || directory == nil ||
		!validBrokerDirectoryOptions(directory.options) || idProof.target.Provider != "entra" ||
		idProof.target.Issuer != brokerIssuer(directory.options.TenantID) ||
		api.config.OIDC.Issuer != idProof.target.Issuer || api.config.OIDC.TenantClaim != "tid" ||
		api.config.OIDC.RequiredScope == "" || !operationIDPattern.MatchString(api.config.OIDC.Audience) ||
		api.config.OIDC.Audience != strings.ToLower(api.config.OIDC.Audience) ||
		!operationIDPattern.MatchString(idProof.target.ClientID) || idProof.target.ClientID != strings.ToLower(idProof.target.ClientID) ||
		api.config.OIDC.Audience == idProof.target.ClientID || len(api.config.OIDC.AllowedClientIDs) != 1 ||
		api.config.OIDC.AllowedClientIDs[0] != idProof.target.ClientID {
		return nil, protocolError(400, "invalid_identity_configuration")
	}
	return &brokerProofVerifier{api: api, idProof: idProof, directory: directory}, nil
}

func (v *brokerProofVerifier) verify(ctx context.Context, accessToken, idToken, challenge string) (verifiedDirectoryProof, error) {
	proof, err := verifyBrokerProofPair(ctx, v.api, v.idProof, v.directory.options.TenantID, accessToken, idToken, challenge)
	if err != nil {
		return verifiedDirectoryProof{}, err
	}
	binding, err := v.directory.lookup(ctx, proof.BrokerObjectID)
	if err != nil {
		return verifiedDirectoryProof{}, err
	}
	// API and native ID subjects may differ. Only signed oid/tid correlate them;
	// ownership derives from the freshly read, namespaced upstream identity.
	proof.Subject, proof.BrokerBinding = brokerIdentitySubject(binding), binding
	if !validBrokerDirectoryProof(proof) {
		return verifiedDirectoryProof{}, protocolError(401, "identity_fresh_proof_required")
	}
	return proof, nil
}

func (v *brokerProofVerifier) verifyAPI(ctx context.Context, accessToken string) (verifiedAccessPrincipal, error) {
	return verifyBrokerAPI(ctx, v.api, v.idProof.target, v.directory.options.TenantID, accessToken)
}

func verifyBrokerAPI(ctx context.Context, api *Server, target identityProofTarget, tenant, accessToken string) (verifiedAccessPrincipal, error) {
	invalid := func() (verifiedAccessPrincipal, error) {
		return verifiedAccessPrincipal{}, protocolError(401, "identity_session_invalid")
	}
	if accessToken == "" || len(accessToken) > 32768 {
		return invalid()
	}
	principal, err := api.verifyAccessPrincipal(ctx, accessToken)
	if err != nil {
		return verifiedAccessPrincipal{}, err
	}
	if principal.Identity.Issuer != target.Issuer || principal.TenantID != tenant ||
		principal.ClientID != target.ClientID || principal.Version != "2.0" ||
		!operationIDPattern.MatchString(principal.ObjectID) || principal.ObjectID != strings.ToLower(principal.ObjectID) {
		return invalid()
	}
	return principal, nil
}

func verifyBrokerProofPair(ctx context.Context, api *Server, idProof *directoryProofVerifier, tenant, accessToken, idToken, challenge string) (verifiedDirectoryProof, error) {
	principal, err := verifyBrokerAPI(ctx, api, idProof.target, tenant, accessToken)
	if err != nil {
		return verifiedDirectoryProof{}, err
	}
	proof, err := idProof.verify(ctx, idToken, challenge)
	if err != nil {
		return verifiedDirectoryProof{}, err
	}
	if proof.BrokerObjectID != principal.ObjectID || proof.BrokerTenantID != principal.TenantID || proof.BrokerVersion != "2.0" {
		return verifiedDirectoryProof{}, protocolError(401, "identity_fresh_proof_required")
	}
	return proof, nil
}

// VerifyFreshBrokerAuthentication checks authentication evidence only. It does
// not read Graph, admit a directory session, register ownership or consume the
// challenge. Those checks still belong to the authenticated lifecycle route.
func VerifyFreshBrokerAuthentication(ctx context.Context, config Config, callback, challenge, selectedObjectID, accessToken, idToken string) error {
	targets, err := identityProofTargets(config, config.Authorization.Directory)
	if err != nil || config.Authorization.Mode != "directory" ||
		!operationIDPattern.MatchString(selectedObjectID) || selectedObjectID != strings.ToLower(selectedObjectID) {
		return protocolError(400, "invalid_identity_configuration")
	}
	var selected *identityProofTarget
	for _, target := range targets {
		if target.Callback == callback {
			selected = &target
			break
		}
	}
	if selected == nil {
		return protocolError(400, "invalid_identity_configuration")
	}
	ctx = oidc.ClientContext(ctx, brokerHTTPClient(ctx))
	provider, err := oidc.NewProvider(ctx, config.OIDC.Issuer)
	if err != nil {
		return protocolError(503, "identity_binding_unavailable")
	}
	var metadata struct {
		Keys string `json:"jwks_uri"`
	}
	if provider.Claims(&metadata) != nil {
		return protocolError(503, "identity_binding_unavailable")
	}
	idProof, err := newDirectoryProofVerifier(ctx, *selected, metadata.Keys)
	if err != nil {
		return err
	}
	api := &Server{config: config, verifier: provider.VerifierContext(ctx, &oidc.Config{
		ClientID: config.OIDC.Audience,
		SupportedSigningAlgs: []string{
			oidc.RS256, oidc.RS384, oidc.RS512, oidc.ES256, oidc.ES384, oidc.ES512,
		},
	})}
	proof, err := verifyBrokerProofPair(ctx, api, idProof, config.Authorization.Directory.TenantID, accessToken, idToken, challenge)
	if err != nil {
		return err
	}
	if proof.BrokerObjectID != selectedObjectID {
		return protocolError(401, "identity_fresh_proof_required")
	}
	return nil
}

func (v *brokerProofVerifier) resolve(ctx context.Context, accessToken string, directory *identityDirectory) (directoryAccount, directorySession, error) {
	principal, err := v.verifyAPI(ctx, accessToken)
	if err != nil {
		return directoryAccount{}, directorySession{}, err
	}
	if directory == nil || directory.store == nil || !directory.brokerTargets[v.idProof.target] {
		return directoryAccount{}, directorySession{}, protocolError(503, "identity_directory_unavailable")
	}
	binding, err := v.directory.lookup(ctx, principal.ObjectID)
	if err != nil {
		return directoryAccount{}, directorySession{}, err
	}
	ctx = withAuthorizationSessions(ctx)
	state, version, err := directory.load(ctx)
	if err != nil {
		return directoryAccount{}, directorySession{}, err
	}
	if state == nil && version == "" {
		return directoryAccount{}, directorySession{}, protocolError(401, "identity_registration_required")
	}
	if version == "" || !validIdentityDirectory(state) {
		return directoryAccount{}, directorySession{}, protocolError(503, "identity_directory_unavailable")
	}
	proof := verifiedDirectoryProof{Target: v.idProof.target, Subject: brokerIdentitySubject(binding), BrokerBinding: binding}
	if err := checkDirectoryBrokerOwnership(state, proof); err != nil {
		return directoryAccount{}, directorySession{}, err
	}
	identityID := proof.identity().id()
	record, exists := state.Bindings[identityID]
	if !exists {
		return directoryAccount{}, directorySession{}, protocolError(401, "identity_registration_required")
	}
	if !matchesRecordedBrokerBinding(record, proof) {
		return directoryAccount{}, directorySession{}, protocolError(401, "identity_binding_changed")
	}
	session := directorySession{record.AccountID, state.Accounts[record.AccountID].Generation, identityID, principal.ExpiresAt}
	account, err := directorySessionAccount(state, session, directory.now())
	if err != nil {
		return directoryAccount{}, directorySession{}, err
	}
	return account, session, nil
}

func newBrokerIdentityDirectory(store identityDirectoryStore, targets []identityProofTarget) (*identityDirectory, error) {
	directory, err := newIdentityDirectory(store, targets)
	if err != nil {
		return nil, err
	}
	directory.brokerTargets = make(map[identityProofTarget]bool, len(targets))
	for _, target := range targets {
		if brokerTenant(target.Issuer) == "" || target.Provider != "entra" ||
			!operationIDPattern.MatchString(target.ClientID) || target.ClientID != strings.ToLower(target.ClientID) {
			return nil, protocolError(400, "invalid_identity_configuration")
		}
		directory.brokerTargets[target] = true
	}
	return directory, nil
}

func bindingFromDirectoryProof(accountID string, proof verifiedDirectoryProof) directoryBinding {
	binding := directoryBinding{AccountID: accountID, Identity: proof.identity(), Active: true}
	if proof.BrokerBinding != (verifiedBrokerBinding{}) {
		broker := proof.BrokerBinding
		binding.Broker = &broker
	}
	return binding
}

func matchesRecordedBrokerBinding(binding directoryBinding, proof verifiedDirectoryProof) bool {
	if binding.Broker == nil {
		return proof.BrokerBinding == (verifiedBrokerBinding{})
	}
	return *binding.Broker == proof.BrokerBinding
}

func checkDirectoryBrokerOwnership(state *identityDirectoryState, proof verifiedDirectoryProof) error {
	if proof.BrokerBinding == (verifiedBrokerBinding{}) {
		return nil
	}
	object := directoryBrokerObjectID(proof.identity(), proof.BrokerBinding.ObjectID)
	for _, binding := range state.Bindings {
		if binding.Broker != nil && directoryBrokerObjectID(binding.Identity, binding.Broker.ObjectID) == object &&
			(!matchesRecordedBrokerBinding(binding, proof) || binding.Identity.id() != proof.identity().id()) {
			return protocolError(401, "identity_binding_changed")
		}
	}
	return nil
}
