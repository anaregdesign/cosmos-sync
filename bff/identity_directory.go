package syncbff

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"slices"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	identityChallengeLifetime = 300 * time.Second
	maxIdentityAccounts       = 64
	maxIdentityBindings       = 256
	maxIdentityChallenges     = 256
	maxIdentityProofs         = 512
	maxIdentityAudits         = 256
	maxIdentityDirectoryBytes = 512 * 1024
	maxAccountIdentities      = 8
	maxOpenIdentityChallenges = 4
	maxIdentityGeneration     = 10000
)

// This internal core has no production factory, configuration or HTTP route.
// A future caller must independently verify upstream identity, auth_time,
// challenge binding and broker-side linking controls before creating proof values.
type identityDirectory struct {
	store   identityDirectoryStore
	targets map[identityProofTarget]bool
	now     func() time.Time
	entropy io.Reader
}

type identityDirectoryStore interface {
	loadIdentityDirectory(context.Context) (*identityDirectoryState, string, error)
	compareIdentityDirectory(context.Context, string, *identityDirectoryState) error
}

type identityProofTarget struct {
	Issuer    string `json:"issuer"`
	Provider  string `json:"provider"`
	Namespace string `json:"namespace"`
	ClientID  string `json:"clientId"`
	Callback  string `json:"callback"`
}

type directoryIdentity struct {
	Issuer    string `json:"issuer"`
	Provider  string `json:"provider"`
	Namespace string `json:"namespace"`
	ClientID  string `json:"clientId"`
	Subject   string `json:"subject"`
}

type verifiedDirectoryProof struct {
	Target          identityProofTarget
	Subject         string
	AuthenticatedAt time.Time
	ExpiresAt       time.Time
	ChallengeDigest string
	ProofDigest     string
}

func (p verifiedDirectoryProof) identity() directoryIdentity {
	return directoryIdentity{p.Target.Issuer, p.Target.Provider, p.Target.Namespace, p.Target.ClientID, p.Subject}
}

func (i directoryIdentity) id() string {
	return namespacedID("identity-binding-v1", i.Issuer, i.Provider, i.Namespace, i.ClientID, i.Subject)
}

type directoryAccount struct {
	Account
	Generation  int64    `json:"generation"`
	IdentityIDs []string `json:"identityIds"`
}

type directorySession struct {
	AccountID  string
	Generation int64
	IdentityID string
	ExpiresAt  time.Time
}

type directoryBinding struct {
	AccountID string            `json:"accountId"`
	Identity  directoryIdentity `json:"identity"`
	Active    bool              `json:"active"`
}

type directoryChallenge struct {
	AccountID        string              `json:"accountId,omitempty"`
	Generation       int64               `json:"generation,omitempty"`
	Operation        string              `json:"operation"`
	Target           identityProofTarget `json:"target"`
	RemoveIdentityID string              `json:"removeIdentityId,omitempty"`
	IssuedAt         time.Time           `json:"issuedAt"`
	ExpiresAt        time.Time           `json:"expiresAt"`
	Consumed         bool                `json:"consumed"`
}

type directoryAudit struct {
	AccountID       string    `json:"accountId"`
	IdentityID      string    `json:"identityId"`
	Generation      int64     `json:"generation"`
	Operation       string    `json:"operation"`
	ChallengeDigest string    `json:"challengeDigest"`
	ProofDigests    []string  `json:"proofDigests"`
	OccurredAt      time.Time `json:"occurredAt"`
}

type identityDirectoryState struct {
	Revision   int64                         `json:"revision"`
	Accounts   map[string]directoryAccount   `json:"accounts"`
	Bindings   map[string]directoryBinding   `json:"bindings"`
	Challenges map[string]directoryChallenge `json:"challenges"`
	Proofs     map[string]string             `json:"proofs"`
	Audits     []directoryAudit              `json:"audits"`
}

func newIdentityDirectory(store identityDirectoryStore, targets []identityProofTarget) (*identityDirectory, error) {
	if store == nil || len(targets) == 0 || len(targets) > 16 {
		return nil, protocolError(400, "invalid_identity_configuration")
	}
	d := &identityDirectory{store: store, targets: make(map[identityProofTarget]bool), now: time.Now, entropy: rand.Reader}
	for _, target := range targets {
		if !validIdentityTarget(target) || d.targets[target] {
			return nil, protocolError(400, "invalid_identity_configuration")
		}
		d.targets[target] = true
	}
	return d, nil
}

func validIdentityText(value string, limit int) bool {
	return value != "" && len(value) <= limit && utf8.ValidString(value) &&
		strings.TrimSpace(value) == value && !strings.ContainsAny(value, "\x00\r\n\t")
}

func validIdentityTarget(target identityProofTarget) bool {
	issuer, err := url.Parse(target.Issuer)
	if err != nil || issuer.Scheme != "https" || issuer.Host == "" || issuer.User != nil || issuer.RawQuery != "" || issuer.Fragment != "" ||
		!validIdentityText(target.Issuer, 512) || !validIdentityText(target.Namespace, 128) || !validIdentityText(target.ClientID, 128) {
		return false
	}
	callback, err := url.Parse(target.Callback)
	return err == nil && callback.Scheme != "" && callback.Host != "" && callback.User == nil &&
		callback.RawQuery == "" && callback.Fragment == "" && validIdentityText(target.Callback, 2048) &&
		(callback.Scheme == "https" || callback.Scheme == "http" &&
			(callback.Hostname() == "localhost" || callback.Hostname() == "127.0.0.1" || callback.Hostname() == "::1") ||
			strings.Contains(callback.Scheme, ".")) &&
		(target.Provider == "google" || target.Provider == "apple" || target.Provider == "entra")
}

func validDirectoryIdentity(identity directoryIdentity) bool {
	return validIdentityTarget(identityProofTarget{identity.Issuer, identity.Provider, identity.Namespace, identity.ClientID, "https://callback.invalid/"}) &&
		validIdentityText(identity.Subject, 512)
}

func emptyIdentityDirectory() *identityDirectoryState {
	return &identityDirectoryState{
		Accounts: make(map[string]directoryAccount), Bindings: make(map[string]directoryBinding),
		Challenges: make(map[string]directoryChallenge), Proofs: make(map[string]string), Audits: []directoryAudit{},
	}
}

func validIdentityDirectory(state *identityDirectoryState) bool {
	if state == nil || state.Revision < 1 || state.Revision > maxIdentityGeneration ||
		state.Accounts == nil || state.Bindings == nil || state.Challenges == nil || state.Proofs == nil || state.Audits == nil ||
		len(state.Accounts) > maxIdentityAccounts || len(state.Bindings) > maxIdentityBindings || len(state.Challenges) > maxIdentityChallenges ||
		len(state.Proofs) > maxIdentityProofs || len(state.Audits) > maxIdentityAudits {
		return false
	}
	for id, account := range state.Accounts {
		if !accountIDPattern.MatchString(id) || account.AccountID != id || account.PersonalScopeID != personalScopeID(id) ||
			account.Generation < 1 || account.Generation > maxIdentityGeneration || len(account.IdentityIDs) == 0 || len(account.IdentityIDs) > maxAccountIdentities {
			return false
		}
		seen := make(map[string]bool)
		for _, identityID := range account.IdentityIDs {
			binding, exists := state.Bindings[identityID]
			if !exists || !binding.Active || binding.AccountID != id || seen[identityID] {
				return false
			}
			seen[identityID] = true
		}
	}
	for id, binding := range state.Bindings {
		account, exists := state.Accounts[binding.AccountID]
		if !exists || !validDirectoryIdentity(binding.Identity) || id != binding.Identity.id() || binding.Active != slices.Contains(account.IdentityIDs, id) {
			return false
		}
	}
	audits := make(map[string]directoryAudit)
	for _, audit := range state.Audits {
		account, exists := state.Accounts[audit.AccountID]
		binding, bound := state.Bindings[audit.IdentityID]
		challenge, challenged := state.Challenges[audit.ChallengeDigest]
		if !exists || !bound || binding.AccountID != audit.AccountID || !challenged || !challenge.Consumed ||
			audit.Operation != challenge.Operation || audit.Generation < 1 || audit.Generation > account.Generation || audit.OccurredAt.IsZero() ||
			len(audit.ProofDigests) == 0 || len(audit.ProofDigests) > 2 {
			return false
		}
		if _, duplicate := audits[audit.ChallengeDigest]; duplicate {
			return false
		}
		if audit.Operation == "register" {
			if audit.Generation != 1 || len(audit.ProofDigests) != 1 {
				return false
			}
		} else if audit.AccountID != challenge.AccountID || audit.Generation != challenge.Generation+1 {
			return false
		}
		if audit.Operation == "link" && len(audit.ProofDigests) != 2 {
			return false
		}
		if audit.Operation == "unlink" && audit.IdentityID != challenge.RemoveIdentityID {
			return false
		}
		seen := make(map[string]bool)
		for _, digest := range audit.ProofDigests {
			if !accountIDPattern.MatchString(digest) || state.Proofs[digest] != audit.ChallengeDigest || seen[digest] {
				return false
			}
			seen[digest] = true
		}
		audits[audit.ChallengeDigest] = audit
	}
	for digest, challenge := range state.Challenges {
		if !accountIDPattern.MatchString(digest) || !validIdentityTarget(challenge.Target) || challenge.IssuedAt.IsZero() ||
			!challenge.ExpiresAt.Equal(challenge.IssuedAt.Add(identityChallengeLifetime)) {
			return false
		}
		if challenge.Operation == "register" {
			if challenge.AccountID != "" || challenge.Generation != 0 || challenge.RemoveIdentityID != "" {
				return false
			}
		} else {
			account, exists := state.Accounts[challenge.AccountID]
			if !exists || challenge.Generation < 1 || challenge.Generation > account.Generation || (challenge.Operation != "link" && challenge.Operation != "unlink") ||
				(challenge.Operation == "link" && challenge.RemoveIdentityID != "") {
				return false
			}
			if challenge.Operation == "unlink" {
				binding, exists := state.Bindings[challenge.RemoveIdentityID]
				if !exists || binding.AccountID != challenge.AccountID {
					return false
				}
			}
		}
		_, audited := audits[digest]
		if challenge.Consumed != audited {
			return false
		}
	}
	for digest, challengeDigest := range state.Proofs {
		audit, exists := audits[challengeDigest]
		if !accountIDPattern.MatchString(digest) || !exists || !slices.Contains(audit.ProofDigests, digest) {
			return false
		}
	}
	body, err := encodeJSON(state)
	return err == nil && len(body) <= maxIdentityDirectoryBytes
}

func (d *identityDirectory) edit(ctx context.Context, apply func(*identityDirectoryState, time.Time) error) error {
	ctx = withAuthorizationSessions(ctx)
	for attempt := 0; attempt < 8; attempt++ {
		if err := ctx.Err(); err != nil {
			return err
		}
		state, version, err := d.store.loadIdentityDirectory(ctx)
		if err != nil {
			return err
		}
		if state == nil {
			if version != "" {
				return protocolError(503, "identity_directory_unavailable")
			}
			state = emptyIdentityDirectory()
		} else {
			if version == "" || !validIdentityDirectory(state) {
				return protocolError(503, "identity_directory_unavailable")
			}
			body, err := encodeJSON(state)
			if err != nil {
				return protocolError(503, "identity_directory_unavailable")
			}
			var copy identityDirectoryState
			if json.Unmarshal(body, &copy) != nil {
				return protocolError(503, "identity_directory_unavailable")
			}
			state = &copy
		}
		if err := apply(state, d.now().UTC().Truncate(time.Second)); err != nil {
			return err
		}
		state.Revision++
		if state.Revision > maxIdentityGeneration || len(state.Accounts) > maxIdentityAccounts || len(state.Bindings) > maxIdentityBindings ||
			len(state.Challenges) > maxIdentityChallenges || len(state.Proofs) > maxIdentityProofs || len(state.Audits) > maxIdentityAudits {
			return protocolError(507, "identity_directory_capacity_exceeded")
		}
		body, err := encodeJSON(state)
		if err != nil {
			return protocolError(503, "identity_directory_unavailable")
		}
		if len(body) > maxIdentityDirectoryBytes {
			return protocolError(507, "identity_directory_capacity_exceeded")
		}
		if !validIdentityDirectory(state) {
			return protocolError(503, "identity_directory_unavailable")
		}
		err = d.store.compareIdentityDirectory(ctx, version, state)
		if err == nil {
			return nil
		}
		var failure *ProtocolError
		if !errors.As(err, &failure) || failure.Code != "authorization_contention" {
			return err
		}
	}
	return &ProtocolError{Status: 503, Code: "identity_directory_contention", RetryAfter: "1"}
}

func (d *identityDirectory) randomID() (string, error) {
	var value [32]byte
	if _, err := io.ReadFull(d.entropy, value[:]); err != nil {
		return "", protocolError(503, "identity_entropy_unavailable")
	}
	return hex.EncodeToString(value[:]), nil
}

func identityChallengeDigest(raw string) (string, error) {
	if !accountIDPattern.MatchString(raw) {
		return "", protocolError(400, "invalid_identity_challenge")
	}
	value := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(value[:]), nil
}

func (d *identityDirectory) begin(ctx context.Context, session *directorySession, operation string, target identityProofTarget, removeIdentityID string) (string, error) {
	if !d.targets[target] || (operation != "register" && operation != "link" && operation != "unlink") ||
		(operation == "register") != (session == nil) || (operation == "unlink") != (removeIdentityID != "") {
		return "", protocolError(400, "invalid_identity_request")
	}
	raw, err := d.randomID()
	if err != nil {
		return "", err
	}
	digest, err := identityChallengeDigest(raw)
	if err != nil {
		return "", err
	}
	err = d.edit(ctx, func(state *identityDirectoryState, now time.Time) error {
		challenge := directoryChallenge{Operation: operation, Target: target, RemoveIdentityID: removeIdentityID,
			IssuedAt: now, ExpiresAt: now.Add(identityChallengeLifetime)}
		if session != nil {
			account, err := directorySessionAccount(state, *session, now)
			if err != nil {
				return err
			}
			if operation == "unlink" && (!slices.Contains(account.IdentityIDs, removeIdentityID) || len(account.IdentityIDs) == 1) {
				return protocolError(409, "identity_last_credential")
			}
			open := 0
			for _, existing := range state.Challenges {
				if existing.AccountID == account.AccountID && !existing.Consumed && existing.ExpiresAt.After(now) {
					open++
				}
			}
			if open >= maxOpenIdentityChallenges {
				return protocolError(429, "identity_challenge_limit")
			}
			challenge.AccountID, challenge.Generation = account.AccountID, account.Generation
		}
		if _, exists := state.Challenges[digest]; exists {
			return protocolError(503, "identity_entropy_unavailable")
		}
		state.Challenges[digest] = challenge
		return nil
	})
	if err != nil {
		return "", err
	}
	return raw, nil
}

func directorySessionAccount(state *identityDirectoryState, session directorySession, now time.Time) (directoryAccount, error) {
	account, exists := state.Accounts[session.AccountID]
	binding, bound := state.Bindings[session.IdentityID]
	if !exists || !bound || !binding.Active || binding.AccountID != session.AccountID || account.Generation != session.Generation ||
		!session.ExpiresAt.After(now) || !slices.Contains(account.IdentityIDs, session.IdentityID) {
		return directoryAccount{}, protocolError(401, "identity_session_invalid")
	}
	return account, nil
}

func (d *identityDirectory) verifyProof(proof verifiedDirectoryProof, digest string, challenge directoryChallenge, now time.Time) error {
	if !d.targets[proof.Target] || !validDirectoryIdentity(proof.identity()) || proof.ChallengeDigest != digest ||
		!accountIDPattern.MatchString(proof.ProofDigest) || proof.AuthenticatedAt.IsZero() ||
		proof.AuthenticatedAt.Before(challenge.IssuedAt) || proof.AuthenticatedAt.After(now) ||
		now.Sub(proof.AuthenticatedAt) >= identityChallengeLifetime || !proof.ExpiresAt.After(now) {
		return protocolError(401, "identity_fresh_proof_required")
	}
	return nil
}

func directoryChallengeFor(state *identityDirectoryState, digest, operation string, now time.Time) (directoryChallenge, error) {
	challenge, exists := state.Challenges[digest]
	if !exists || challenge.Consumed || challenge.Operation != operation || !challenge.ExpiresAt.After(now) || now.Before(challenge.IssuedAt) {
		return directoryChallenge{}, protocolError(409, "identity_challenge_invalid")
	}
	return challenge, nil
}

func consumeDirectoryChallenge(state *identityDirectoryState, digest string, challenge directoryChallenge, account directoryAccount, identityID string, proofs []verifiedDirectoryProof, now time.Time) error {
	digests := []string{}
	for _, proof := range proofs {
		if slices.Contains(digests, proof.ProofDigest) {
			continue
		}
		if _, exists := state.Proofs[proof.ProofDigest]; exists {
			return protocolError(409, "identity_proof_replayed")
		}
		digests = append(digests, proof.ProofDigest)
	}
	for _, proofDigest := range digests {
		state.Proofs[proofDigest] = digest
	}
	challenge.Consumed = true
	state.Challenges[digest] = challenge
	state.Accounts[account.AccountID] = account
	state.Audits = append(state.Audits, directoryAudit{AccountID: account.AccountID, IdentityID: identityID,
		Generation: account.Generation, Operation: challenge.Operation, ChallengeDigest: digest, ProofDigests: digests, OccurredAt: now})
	return nil
}

func (d *identityDirectory) register(ctx context.Context, raw string, proof verifiedDirectoryProof) (directoryAccount, error) {
	digest, err := identityChallengeDigest(raw)
	if err != nil {
		return directoryAccount{}, err
	}
	accountID, err := d.randomID()
	if err != nil {
		return directoryAccount{}, err
	}
	var result directoryAccount
	err = d.edit(ctx, func(state *identityDirectoryState, now time.Time) error {
		challenge, err := directoryChallengeFor(state, digest, "register", now)
		if err != nil {
			return err
		}
		if err := d.verifyProof(proof, digest, challenge, now); err != nil {
			return err
		}
		if proof.Target != challenge.Target {
			return protocolError(401, "identity_fresh_proof_required")
		}
		id := proof.identity().id()
		if _, exists := state.Bindings[id]; exists {
			return protocolError(409, "identity_already_assigned")
		}
		if _, exists := state.Accounts[accountID]; exists {
			return protocolError(503, "identity_entropy_unavailable")
		}
		result = directoryAccount{Account: Account{AccountID: accountID, PersonalScopeID: personalScopeID(accountID)},
			Generation: 1, IdentityIDs: []string{id}}
		state.Bindings[id] = directoryBinding{AccountID: accountID, Identity: proof.identity(), Active: true}
		return consumeDirectoryChallenge(state, digest, challenge, result, id, []verifiedDirectoryProof{proof}, now)
	})
	if err != nil {
		return directoryAccount{}, err
	}
	return result, nil
}

func (d *identityDirectory) change(ctx context.Context, session directorySession, raw, operation string, reauthentication, independent verifiedDirectoryProof) (directoryAccount, error) {
	if operation != "link" && operation != "unlink" {
		return directoryAccount{}, protocolError(400, "invalid_identity_request")
	}
	digest, err := identityChallengeDigest(raw)
	if err != nil {
		return directoryAccount{}, err
	}
	var result directoryAccount
	err = d.edit(ctx, func(state *identityDirectoryState, now time.Time) error {
		account, err := directorySessionAccount(state, session, now)
		if err != nil {
			return err
		}
		challenge, err := directoryChallengeFor(state, digest, operation, now)
		if err != nil {
			return err
		}
		if challenge.AccountID != session.AccountID || challenge.Generation != session.Generation {
			return protocolError(409, "identity_challenge_invalid")
		}
		for _, proof := range []verifiedDirectoryProof{reauthentication, independent} {
			if err := d.verifyProof(proof, digest, challenge, now); err != nil {
				return err
			}
		}
		if reauthentication.identity().id() != session.IdentityID || independent.Target != challenge.Target ||
			(reauthentication.ProofDigest == independent.ProofDigest && (operation == "link" || reauthentication != independent)) {
			return protocolError(401, "identity_fresh_proof_required")
		}
		identityID := independent.identity().id()
		binding, exists := state.Bindings[identityID]
		if operation == "link" {
			if exists && (binding.AccountID != account.AccountID || binding.Active) {
				return protocolError(409, "identity_already_assigned")
			}
			if len(account.IdentityIDs) >= maxAccountIdentities {
				return protocolError(409, "identity_credential_limit")
			}
			account.IdentityIDs = append(slices.Clone(account.IdentityIDs), identityID)
			state.Bindings[identityID] = directoryBinding{AccountID: account.AccountID, Identity: independent.identity(), Active: true}
		} else {
			if !exists || !binding.Active || binding.AccountID != account.AccountID || identityID == challenge.RemoveIdentityID ||
				!slices.Contains(account.IdentityIDs, challenge.RemoveIdentityID) || len(account.IdentityIDs) <= 1 {
				return protocolError(409, "identity_last_credential")
			}
			identityID = challenge.RemoveIdentityID
			removed := state.Bindings[identityID]
			removed.Active = false
			state.Bindings[identityID] = removed
			account.IdentityIDs = slices.DeleteFunc(slices.Clone(account.IdentityIDs), func(id string) bool { return id == identityID })
		}
		if account.Generation >= maxIdentityGeneration {
			return protocolError(507, "identity_directory_capacity_exceeded")
		}
		account.Generation++
		result = account
		return consumeDirectoryChallenge(state, digest, challenge, account, identityID,
			[]verifiedDirectoryProof{reauthentication, independent}, now)
	})
	if err != nil {
		return directoryAccount{}, err
	}
	return result, nil
}
