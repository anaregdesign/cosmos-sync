package syncbff

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"slices"
	"strings"
	"time"
)

const maxIdentityRequestBytes = 128 * 1024

type identityProofRequest struct {
	AccessToken string `json:"accessToken"`
	IDToken     string `json:"idToken"`
}

type identityCredentialResponse struct {
	IdentityID string `json:"identityId"`
	Provider   string `json:"provider"`
}

type identityAccountResponse struct {
	Account
	IdentityGeneration int64                        `json:"identityGeneration"`
	CurrentIdentityID  string                       `json:"currentIdentityId,omitempty"`
	Identities         []identityCredentialResponse `json:"identities"`
}

func (runtime *identityRuntime) accountResponse(r *http.Request, account directoryAccount, current string) (identityAccountResponse, error) {
	state, _, err := runtime.directory.load(r.Context())
	if err != nil {
		return identityAccountResponse{}, err
	}
	if state == nil || !validDirectoryAccount(account) || state.Accounts[account.AccountID].Generation != account.Generation ||
		state.Accounts[account.AccountID].Account != account.Account ||
		!slices.Equal(state.Accounts[account.AccountID].IdentityIDs, account.IdentityIDs) {
		return identityAccountResponse{}, protocolError(401, "identity_session_invalid")
	}
	result := identityAccountResponse{Account: account.Account, IdentityGeneration: account.Generation,
		Identities: make([]identityCredentialResponse, 0, len(account.IdentityIDs))}
	for _, id := range account.IdentityIDs {
		binding := state.Bindings[id]
		result.Identities = append(result.Identities, identityCredentialResponse{id, binding.Identity.Provider})
	}
	if slices.Contains(account.IdentityIDs, current) {
		result.CurrentIdentityID = current
	}
	return result, nil
}

func (s *Server) serveIdentity(w http.ResponseWriter, r *http.Request, token string) bool {
	if s.directory == nil {
		return false
	}
	path := r.URL.Path
	if path != "/v1/identity/capabilities" && path != "/v1/identities" && path != "/v1/identity/challenges" &&
		path != "/v1/identity/register" && path != "/v1/identities/link" && path != "/v1/identities/unlink" {
		return false
	}
	runtime := s.directory
	principal, err := runtime.resolver.verifyAPI(r.Context(), token)
	if err != nil {
		s.writeError(w, err)
		return true
	}
	if !s.controls.allowPrincipal(namespacedID("identity-rate-v1", principal.Identity.Issuer, principal.ObjectID, principal.ClientID)) {
		s.writeError(w, &ProtocolError{Status: 429, Code: "rate_limit", RetryAfter: "1"})
		return true
	}
	switch {
	case path == "/v1/identity/capabilities" && r.Method == http.MethodGet:
		if _, err := runtime.resolver.directory.lookup(r.Context(), principal.ObjectID); err != nil {
			s.writeError(w, err)
			return true
		}
		targets := make([]identityProofTarget, 0, len(s.config.Authorization.Directory.Callbacks))
		for _, callback := range s.config.Authorization.Directory.Callbacks {
			targets = append(targets, runtime.proofs[callback].idProof.target)
		}
		writeJSON(w, 200, map[string]any{"version": 1, "targets": targets, "freshAuthenticationSeconds": 300,
			"maximumIdentities": maxAccountIdentities, "recovery": "remaining-identity-only",
			"deletion": "operator-review-required", "migration": "operator-review-required"})
	case path == "/v1/identity/challenges" && r.Method == http.MethodPost:
		var request struct {
			Operation        string `json:"operation"`
			Callback         string `json:"callback"`
			RemoveIdentityID string `json:"removeIdentityId,omitempty"`
		}
		var proof *brokerProofVerifier
		if decodeIdentityRequest(w, r, &request) == nil {
			proof = runtime.proofs[request.Callback]
		}
		if proof == nil || (request.Operation != "register" && request.Operation != "link" && request.Operation != "unlink") ||
			(request.Operation == "unlink") != (request.RemoveIdentityID != "") {
			s.writeError(w, protocolError(400, "invalid_identity_request"))
			return true
		}
		var session *directorySession
		if request.Operation == "register" {
			if err := checkIdentityRequestBinding(r, Scope{}); err != nil || len(r.Header.Values(PrincipalHeader)) != 0 {
				s.writeError(w, protocolError(401, "identity_session_invalid"))
				return true
			}
			binding, err := proof.directory.lookup(r.Context(), principal.ObjectID)
			if err != nil {
				s.writeError(w, err)
				return true
			}
			state, _, err := runtime.directory.load(r.Context())
			if err != nil {
				s.writeError(w, err)
				return true
			}
			if state != nil {
				candidate := verifiedDirectoryProof{Target: proof.idProof.target, Subject: brokerIdentitySubject(binding), BrokerBinding: binding}
				if err := checkDirectoryBrokerOwnership(state, candidate); err != nil {
					s.writeError(w, err)
					return true
				}
				if _, exists := state.Bindings[candidate.identity().id()]; exists {
					s.writeError(w, protocolError(409, "identity_already_assigned"))
					return true
				}
			}
		} else {
			_, current, err := runtime.resolve(r.Context(), token)
			if err == nil {
				err = checkDirectoryRequestBinding(r, current)
			}
			if err != nil {
				s.writeError(w, err)
				return true
			}
			session = &current
		}
		raw, err := runtime.directory.begin(r.Context(), session, request.Operation, proof.idProof.target, request.RemoveIdentityID)
		if err != nil {
			s.writeError(w, err)
			return true
		}
		state, _, err := runtime.directory.load(r.Context())
		if err != nil || state == nil {
			if err == nil {
				err = protocolError(503, "identity_directory_unavailable")
			}
			s.writeError(w, err)
			return true
		}
		digest, _ := identityChallengeDigest(raw)
		challenge, exists := state.Challenges[digest]
		if !exists {
			s.writeError(w, protocolError(503, "identity_directory_unavailable"))
			return true
		}
		writeJSON(w, 200, map[string]any{"challenge": raw, "operation": challenge.Operation,
			"expiresAt": challenge.ExpiresAt.Format(time.RFC3339), "target": challenge.Target})
	case path == "/v1/identity/register" && r.Method == http.MethodPost:
		var request struct {
			Challenge string `json:"challenge"`
			IDToken   string `json:"idToken"`
		}
		if decodeIdentityRequest(w, r, &request) != nil {
			s.writeError(w, protocolError(400, "invalid_identity_request"))
			return true
		}
		if err := checkIdentityRequestBinding(r, Scope{}); err != nil || len(r.Header.Values(PrincipalHeader)) != 0 {
			s.writeError(w, protocolError(401, "identity_session_invalid"))
			return true
		}
		verifier, err := runtime.proofForChallenge(r.Context(), request.Challenge, "register")
		if err != nil {
			s.writeError(w, err)
			return true
		}
		proof, err := verifier.verify(r.Context(), token, request.IDToken, request.Challenge)
		if err != nil {
			s.writeError(w, err)
			return true
		}
		account, err := runtime.directory.register(r.Context(), request.Challenge, proof)
		if err == nil {
			_, err = runtime.authorization.ensureDirectoryAccount(r.Context(), account)
		}
		if err != nil {
			s.writeError(w, err)
			return true
		}
		result, err := runtime.accountResponse(r, account, proof.identity().id())
		if err != nil {
			s.writeError(w, err)
		} else {
			writeJSON(w, 200, result)
		}
	case path == "/v1/identities" && r.Method == http.MethodGet:
		account, session, err := runtime.resolve(r.Context(), token)
		if err == nil {
			err = checkDirectoryRequestBinding(r, session)
		}
		if err != nil {
			s.writeError(w, err)
			return true
		}
		result, err := runtime.accountResponse(r, account, session.IdentityID)
		if err != nil {
			s.writeError(w, err)
		} else {
			writeJSON(w, 200, result)
		}
	case (path == "/v1/identities/link" || path == "/v1/identities/unlink") && r.Method == http.MethodPost:
		var request struct {
			Challenge        string               `json:"challenge"`
			Reauthentication identityProofRequest `json:"reauthentication"`
			Identity         identityProofRequest `json:"identity"`
		}
		if decodeIdentityRequest(w, r, &request) != nil {
			s.writeError(w, protocolError(400, "invalid_identity_request"))
			return true
		}
		_, session, err := runtime.resolve(r.Context(), token)
		if err == nil {
			err = checkDirectoryRequestBinding(r, session)
		}
		if err != nil {
			s.writeError(w, err)
			return true
		}
		operation := strings.TrimPrefix(path, "/v1/identities/")
		verifier, err := runtime.proofForChallenge(r.Context(), request.Challenge, operation)
		if err != nil {
			s.writeError(w, err)
			return true
		}
		reauthentication, err := verifier.verify(r.Context(), request.Reauthentication.AccessToken, request.Reauthentication.IDToken, request.Challenge)
		if err != nil {
			s.writeError(w, err)
			return true
		}
		independent, err := verifier.verify(r.Context(), request.Identity.AccessToken, request.Identity.IDToken, request.Challenge)
		if err != nil {
			s.writeError(w, err)
			return true
		}
		account, err := runtime.directory.change(r.Context(), session, request.Challenge, operation, reauthentication, independent)
		if err != nil {
			s.writeError(w, err)
			return true
		}
		result, err := runtime.accountResponse(r, account, session.IdentityID)
		if err != nil {
			s.writeError(w, err)
		} else {
			writeJSON(w, 200, result)
		}
	default:
		s.writeError(w, protocolError(404, "not_found"))
	}
	return true
}

func decodeIdentityRequest(w http.ResponseWriter, r *http.Request, value any) error {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxIdentityRequestBytes))
	if err != nil || validateJSON(body) != nil {
		return protocolError(400, "invalid_identity_request")
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if decoder.Decode(value) != nil {
		return protocolError(400, "invalid_identity_request")
	}
	return nil
}
