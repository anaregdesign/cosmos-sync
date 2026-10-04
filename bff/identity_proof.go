package syncbff

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"golang.org/x/oauth2"
)

const maxDirectoryProofBytes = 16384

// No production factory or route constructs this verifier. A valid ID proof
// does not establish broker binding, OAuth callback integrity or API access.
type directoryProofVerifier struct {
	target   identityProofTarget
	verifier *oidc.IDTokenVerifier
	now      func() time.Time
}

func newDirectoryProofVerifier(ctx context.Context, target identityProofTarget, jwksURL string) (*directoryProofVerifier, error) {
	keys, err := url.Parse(jwksURL)
	if !validIdentityTarget(target) || err != nil || keys.Scheme != "https" || keys.Host == "" || keys.User != nil ||
		keys.RawQuery != "" || keys.Fragment != "" || !validIdentityText(jwksURL, 2048) {
		return nil, protocolError(400, "invalid_identity_configuration")
	}
	client := &http.Client{Timeout: 10 * time.Second}
	if configured, ok := ctx.Value(oauth2.HTTPClient).(*http.Client); ok && configured != nil {
		copy := *configured
		client = &copy
		if client.Timeout <= 0 || client.Timeout > 10*time.Second {
			client.Timeout = 10 * time.Second
		}
	}
	client.Jar = nil
	client.CheckRedirect = func(*http.Request, []*http.Request) error {
		return fmt.Errorf("identity proof key redirects are disabled")
	}
	ctx = oidc.ClientContext(ctx, client)
	result := &directoryProofVerifier{target: target, now: time.Now}
	result.verifier = oidc.NewVerifier(target.Issuer, oidc.NewRemoteKeySet(ctx, jwksURL), &oidc.Config{
		ClientID: target.ClientID,
		SupportedSigningAlgs: []string{
			oidc.RS256, oidc.RS384, oidc.RS512, oidc.ES256, oidc.ES384, oidc.ES512,
		},
		Now: func() time.Time { return result.now() },
	})
	return result, nil
}

func directoryProofDate(raw json.RawMessage) (time.Time, bool) {
	var seconds int64
	if len(raw) == 0 || string(raw) == "null" || json.Unmarshal(raw, &seconds) != nil || seconds <= 0 {
		return time.Time{}, false
	}
	return time.Unix(seconds, 0).UTC(), true
}

func (v *directoryProofVerifier) verify(ctx context.Context, raw, challenge string) (verifiedDirectoryProof, error) {
	invalid := func() (verifiedDirectoryProof, error) {
		return verifiedDirectoryProof{}, protocolError(401, "identity_fresh_proof_required")
	}
	challengeDigest, err := identityChallengeDigest(challenge)
	if err != nil || raw == "" || len(raw) > maxDirectoryProofBytes {
		return invalid()
	}
	if err := ctx.Err(); err != nil {
		return verifiedDirectoryProof{}, err
	}
	verified, err := v.verifier.Verify(ctx, raw)
	if err != nil {
		if err := ctx.Err(); err != nil {
			return verifiedDirectoryProof{}, err
		}
		return invalid()
	}
	if len(verified.Audience) != 1 || verified.Audience[0] != v.target.ClientID || !validIdentityText(verified.Subject, 512) {
		return invalid()
	}
	parts := strings.Split(raw, ".")
	if len(parts) != 3 {
		return invalid()
	}
	headerBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return invalid()
	}
	var header struct {
		Type  string `json:"typ"`
		KeyID string `json:"kid"`
	}
	if json.Unmarshal(headerBytes, &header) != nil || (header.Type != "" && header.Type != "JWT") ||
		!validIdentityText(header.KeyID, 256) {
		return invalid()
	}
	var claims map[string]json.RawMessage
	if verified.Claims(&claims) != nil {
		return invalid()
	}
	var nonce string
	if json.Unmarshal(claims["nonce"], &nonce) != nil || subtle.ConstantTimeCompare([]byte(nonce), []byte(challenge)) != 1 {
		return invalid()
	}
	authenticated, validAuth := directoryProofDate(claims["auth_time"])
	issued, validIssued := directoryProofDate(claims["iat"])
	expires, validExpires := directoryProofDate(claims["exp"])
	now := v.now().UTC().Truncate(time.Second)
	if !validAuth || !validIssued || !validExpires || authenticated.After(issued) || issued.After(now) ||
		authenticated.After(now) || now.Sub(authenticated) >= identityChallengeLifetime || !expires.After(now) || !expires.After(issued) {
		return invalid()
	}
	if rawNotBefore, present := claims["nbf"]; present {
		notBefore, valid := directoryProofDate(rawNotBefore)
		if !valid || notBefore.After(now) || !expires.After(notBefore) {
			return invalid()
		}
	}
	for _, name := range []string{"scp", "scope"} {
		if _, present := claims[name]; present {
			return invalid()
		}
	}
	if rawUse, present := claims["token_use"]; present {
		var use string
		if json.Unmarshal(rawUse, &use) != nil || use != "id" {
			return invalid()
		}
	}
	if rawClient, present := claims["azp"]; present {
		var client string
		if json.Unmarshal(rawClient, &client) != nil || client != v.target.ClientID {
			return invalid()
		}
	}
	digest := sha256.Sum256([]byte(raw))
	return verifiedDirectoryProof{
		Target: v.target, Subject: verified.Subject, AuthenticatedAt: authenticated, ExpiresAt: expires,
		ChallengeDigest: challengeDigest, ProofDigest: hex.EncodeToString(digest[:]),
	}, nil
}
