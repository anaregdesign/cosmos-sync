// verify-entra-principal verifies an actual API access JWT before proposing a
// single-user grant. It neither applies grants nor authenticates to Azure.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"syscall"
	"time"

	syncbff "github.com/anaregdesign/cosmos-sync/bff"
	"github.com/coreos/go-oidc/v3/oidc"
	"golang.org/x/sys/unix"
)

const requiredScope = "Cosmos.Sync"

var guid = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

type ownerRecord struct {
	TenantID      string `json:"tenantId"`
	OwnerObjectID string `json:"ownerObjectId"`
}

type registrationReceipt struct {
	TenantID              string             `json:"tenantId"`
	OwnerObjectID         string             `json:"ownerObjectId"`
	ConfigurationVerified bool               `json:"configurationVerified"`
	OIDC                  syncbff.OIDCConfig `json:"oidc"`
	API                   struct {
		AppID string `json:"appId"`
	} `json:"api"`
	Native struct {
		AppID string `json:"appId"`
	} `json:"native"`
}

type identity struct {
	Issuer            string    `json:"issuer"`
	Audience          string    `json:"audience"`
	TenantID          string    `json:"tenantId"`
	OwnerObjectID     string    `json:"ownerObjectId"`
	Subject           string    `json:"subject"`
	AccessTokenExpiry time.Time `json:"accessTokenExpiry"`
}

// proof deliberately contains no identifiers, hashes, claims, tokens, paths,
// timestamps, or provider error strings and may be shared as validation evidence.
type proof struct {
	VerifiedSignature      bool `json:"verifiedSignature"`
	VerifiedIssuer         bool `json:"verifiedIssuer"`
	VerifiedAPIAudience    bool `json:"verifiedApiAudience"`
	VerifiedLifetime       bool `json:"verifiedLifetime"`
	VerifiedV2             bool `json:"verifiedV2"`
	VerifiedDelegatedScope bool `json:"verifiedDelegatedScope"`
	VerifiedSelectedTenant bool `json:"verifiedSelectedTenant"`
	VerifiedSelectedOwner  bool `json:"verifiedSelectedOwner"`
	SubjectFromAPIToken    bool `json:"subjectFromApiToken"`
	ProposedSingleUserOnly bool `json:"proposedSingleUserOnly"`
	GrantsApplied          bool `json:"grantsApplied"`
}

type options struct {
	OwnerFile, ReceiptFile, TokenFile, OutputDir, PermissionVersion string
	DirectoryConfigFile, Callback                                   string
	FreshProofStdin                                                 bool
}

func main() {
	var opts options
	flags := flag.NewFlagSet("verify-entra-principal", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	flags.StringVar(&opts.OwnerFile, "owner-file", "", "Private 0600 approved-owner JSON file")
	flags.StringVar(&opts.ReceiptFile, "receipt-file", "", "Private 0600 registration-receipt JSON file")
	flags.StringVar(&opts.TokenFile, "token-file", "", "Private 0600 file containing the API access JWT")
	flags.StringVar(&opts.OutputDir, "output-dir", "", "Existing private 0700, Git-ignored directory; files must not exist")
	flags.StringVar(&opts.PermissionVersion, "permission-version", "", "Explicit version for the proposed user grant")
	flags.BoolVar(&opts.FreshProofStdin, "fresh-proof-stdin", false, "Verify transient API/ID fresh authentication evidence from stdin; no grants or token files")
	flags.StringVar(&opts.DirectoryConfigFile, "directory-config-file", "", "Private exact directory runtime configuration for fresh-proof verification")
	flags.StringVar(&opts.Callback, "callback", "", "Exact approved callback for fresh-proof verification")
	err := flags.Parse(os.Args[1:])
	if errors.Is(err, flag.ErrHelp) {
		flags.SetOutput(os.Stdout)
		flags.PrintDefaults()
		return
	}
	if err != nil || flags.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "invalid_arguments")
		os.Exit(1)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if opts.FreshProofStdin {
		if err := runFreshProof(ctx, opts, os.Stdin); err != nil {
			fmt.Fprintln(os.Stderr, "directory_authentication_proof_rejected")
			os.Exit(1)
		}
		_ = json.NewEncoder(os.Stdout).Encode(map[string]bool{
			"independentApiIdSignaturesVerified": true, "selectedObjectTenantCorrelated": true,
			"exactProvidedNonceVerified": true, "recentIntegerAuthenticationTimeVerified": true,
			"brokerProfileVerified": false, "directoryOwnershipRegistered": false,
			"rawProofPersisted": false, "grantsApplied": false,
		})
		return
	}
	if opts.DirectoryConfigFile != "" || opts.Callback != "" {
		fmt.Fprintln(os.Stderr, "invalid_arguments")
		os.Exit(1)
	}
	result, err := run(ctx, opts)
	if err != nil {
		// Do not print provider, filesystem, JWT, claim, or identifier details.
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(1)
	}
	_ = json.NewEncoder(os.Stdout).Encode(result)
}

func code(value string) error { return errors.New(value) }

func run(ctx context.Context, opts options) (proof, error) {
	if opts.OwnerFile == "" || opts.ReceiptFile == "" || opts.TokenFile == "" || opts.OutputDir == "" ||
		!regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`).MatchString(opts.PermissionVersion) {
		return proof{}, code("invalid_arguments")
	}
	ownerBytes, err := readPrivateFile(opts.OwnerFile, 65536)
	if err != nil {
		return proof{}, code("owner_file_rejected")
	}
	receiptBytes, err := readPrivateFile(opts.ReceiptFile, 65536)
	if err != nil {
		return proof{}, code("receipt_file_rejected")
	}
	var owner ownerRecord
	var receipt registrationReceipt
	if json.Unmarshal(ownerBytes, &owner) != nil || json.Unmarshal(receiptBytes, &receipt) != nil ||
		validateConfiguration(owner, receipt) != nil {
		return proof{}, code("configuration_rejected")
	}
	tokenBytes, err := readPrivateFile(opts.TokenFile, 65536)
	if err != nil {
		return proof{}, code("token_file_rejected")
	}
	token := strings.TrimSpace(string(tokenBytes))
	if token == "" || strings.Count(token, ".") != 2 || strings.ContainsAny(token, " \t\r\n") {
		return proof{}, code("token_rejected")
	}
	// Only unauthenticated, pinned-provider discovery/JWKS are requested. No CLI
	// credentials, bearer token, or directory inventory is sent to the provider.
	verifier, err := syncbff.NewOIDCVerifier(ctx, receipt.OIDC)
	if err != nil {
		return proof{}, code("provider_verification_unavailable")
	}
	verifiedIdentity, err := verifyPrincipal(ctx, verifier, token, owner, receipt.OIDC)
	if err != nil {
		return proof{}, err
	}
	grant := syncbff.Grant{
		Tenant: verifiedIdentity.TenantID, Subject: verifiedIdentity.Subject,
		PermissionVersion: opts.PermissionVersion, Active: true,
		CanRead: true, CanWrite: true, ScopeMode: "user",
	}
	result := proof{true, true, true, true, true, true, true, true, true, true, false}
	if err := writeOutputs(opts.OutputDir, verifiedIdentity, []syncbff.Grant{grant}, result); err != nil {
		return proof{}, code("private_output_rejected")
	}
	return result, nil
}

func validateConfiguration(owner ownerRecord, receipt registrationReceipt) error {
	if !guid.MatchString(owner.TenantID) || !guid.MatchString(owner.OwnerObjectID) ||
		!guid.MatchString(receipt.API.AppID) || !guid.MatchString(receipt.Native.AppID) ||
		!strings.EqualFold(owner.TenantID, receipt.TenantID) ||
		!strings.EqualFold(owner.OwnerObjectID, receipt.OwnerObjectID) ||
		strings.EqualFold(receipt.API.AppID, receipt.Native.AppID) ||
		!receipt.ConfigurationVerified {
		return code("configuration_rejected")
	}
	tenant := strings.ToLower(owner.TenantID)
	workforceIssuer := "https://login.microsoftonline.com/" + tenant + "/v2.0"
	customerIssuer := "https://" + tenant + ".ciamlogin.com/" + tenant + "/v2.0"
	if (receipt.OIDC.Issuer != workforceIssuer && receipt.OIDC.Issuer != customerIssuer) ||
		!strings.EqualFold(receipt.OIDC.Audience, receipt.API.AppID) ||
		receipt.OIDC.TenantClaim != "tid" || receipt.OIDC.RequiredScope != requiredScope || receipt.OIDC.TokenUse != "" {
		return code("configuration_rejected")
	}
	if len(receipt.OIDC.AllowedClientIDs) != 0 &&
		(len(receipt.OIDC.AllowedClientIDs) != 1 || receipt.OIDC.AllowedClientIDs[0] != receipt.Native.AppID) {
		return code("configuration_rejected")
	}
	return nil
}

func verifyPrincipal(ctx context.Context, verifier *oidc.IDTokenVerifier, token string, owner ownerRecord, config syncbff.OIDCConfig) (identity, error) {
	verified, err := verifier.Verify(ctx, token)
	if err != nil {
		return identity{}, code("token_verification_failed")
	}
	var claims struct {
		TenantID      string          `json:"tid"`
		OwnerObjectID string          `json:"oid"`
		Version       string          `json:"ver"`
		Delegated     string          `json:"scp"`
		ClientID      string          `json:"azp"`
		NotBefore     json.RawMessage `json:"nbf"`
		IssuedAt      json.RawMessage `json:"iat"`
	}
	if verified.Claims(&claims) != nil || claims.Version != "2.0" || verified.Issuer != config.Issuer ||
		len(verified.Audience) != 1 || verified.Audience[0] != config.Audience ||
		verified.Subject == "" || len(verified.Subject) > 1024 || !guid.MatchString(claims.TenantID) ||
		!guid.MatchString(claims.OwnerObjectID) || !strings.EqualFold(claims.TenantID, owner.TenantID) ||
		!strings.EqualFold(claims.OwnerObjectID, owner.OwnerObjectID) {
		return identity{}, code("verified_claims_rejected")
	}
	if len(config.AllowedClientIDs) != 0 &&
		(len(config.AllowedClientIDs) != 1 || claims.ClientID != config.AllowedClientIDs[0]) {
		return identity{}, code("verified_client_rejected")
	}
	// Entra delegated access JWTs carry scp. Do not accept an application roles
	// token or an ID token merely because it includes a generic scope property.
	allowed := false
	for _, value := range strings.Fields(claims.Delegated) {
		if value == config.RequiredScope {
			allowed = true
		}
	}
	if !allowed {
		return identity{}, code("delegated_scope_rejected")
	}
	// The shared verifier validates signature, issuer, audience, and exp. Entra
	// also requires nbf; reject malformed, absent, future, or inverted lifetimes.
	var nbf, iat int64
	nbfErr := json.Unmarshal(claims.NotBefore, &nbf)
	iatErr := json.Unmarshal(claims.IssuedAt, &iat)
	now := time.Now().Unix()
	if nbfErr != nil || iatErr != nil || nbf <= 0 || iat <= 0 || nbf > now || iat > now ||
		verified.Expiry.Unix() <= now || nbf >= verified.Expiry.Unix() || iat >= verified.Expiry.Unix() {
		return identity{}, code("verified_lifetime_rejected")
	}
	return identity{
		Issuer: verified.Issuer, Audience: config.Audience, TenantID: claims.TenantID,
		OwnerObjectID: claims.OwnerObjectID, Subject: verified.Subject,
		AccessTokenExpiry: verified.Expiry.UTC(),
	}, nil
}

func owned(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && int(stat.Uid) == os.Geteuid()
}

func readPrivateFile(path string, limit int64) ([]byte, error) {
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_CLOEXEC|unix.O_NONBLOCK, 0)
	if err != nil {
		return nil, code("private_file_rejected")
	}
	f := os.NewFile(uintptr(fd), "private-input")
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0600 || !owned(info) || info.Size() > limit {
		return nil, code("private_file_rejected")
	}
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil || int64(len(data)) > limit {
		return nil, code("private_file_rejected")
	}
	return data, nil
}

func writeOutputs(path string, owner identity, grants []syncbff.Grant, result proof) error {
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return code("private_output_rejected")
	}
	dir := os.NewFile(uintptr(fd), "private-output")
	defer dir.Close()
	info, err := dir.Stat()
	if err != nil || !info.IsDir() || info.Mode().Perm() != 0700 || !owned(info) {
		return code("private_output_rejected")
	}
	outputs := []struct {
		name  string
		value any
	}{
		{"identity.local.json", owner},
		{"grants.proposed.local.json", grants},
		{"proof.json", result},
	}
	// Create all outputs exclusively first. Existing files (including symlinks)
	// are never replaced, and failure removes only files created by this run.
	created := make([]string, 0, len(outputs))
	complete := false
	defer func() {
		if !complete {
			for _, name := range created {
				_ = unix.Unlinkat(fd, name, 0)
			}
		}
	}()
	for _, out := range outputs {
		fileFD, err := unix.Openat(fd, out.name, unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0600)
		if err != nil {
			return code("private_output_rejected")
		}
		created = append(created, out.name)
		file := os.NewFile(uintptr(fileFD), "private-output-file")
		data, err := json.MarshalIndent(out.value, "", "  ")
		if err == nil {
			_, err = file.Write(append(data, '\n'))
		}
		if err == nil {
			err = file.Sync()
		}
		closeErr := file.Close()
		if err != nil || closeErr != nil {
			return code("private_output_rejected")
		}
	}
	complete = true
	return nil
}
