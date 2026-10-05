package syncbff

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/cloud"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"golang.org/x/oauth2"
)

const maxBrokerProfileBytes = 64 * 1024

// This component is not yet wired into production account/session routes.
type brokerDirectoryOptions struct {
	TenantID                string
	InitialDomain           string
	ReaderClientID          string
	ManagedIdentityClientID string
	WorkforceTenantIDs      []string
}

type brokerDirectoryReader struct {
	credential azcore.TokenCredential
	client     *http.Client
	options    brokerDirectoryOptions
	issuers    map[string]bool
}

type verifiedBrokerBinding struct {
	ObjectID    string
	Issuer      string
	Subject     string
	Fingerprint string
}

type brokerProfileIdentity struct {
	SignInType       string `json:"signInType"`
	Issuer           string `json:"issuer"`
	IssuerAssignedID string `json:"issuerAssignedId"`
}

type brokerProfile struct {
	ID             string                  `json:"id"`
	AccountEnabled *bool                   `json:"accountEnabled"`
	Identities     []brokerProfileIdentity `json:"identities"`
}

func validBrokerDirectoryOptions(options brokerDirectoryOptions) bool {
	for _, id := range []string{options.TenantID, options.ReaderClientID, options.ManagedIdentityClientID} {
		if !operationIDPattern.MatchString(id) || id != strings.ToLower(id) {
			return false
		}
	}
	if options.ReaderClientID == options.ManagedIdentityClientID || len(options.WorkforceTenantIDs) < 1 || len(options.WorkforceTenantIDs) > 16 ||
		len(options.InitialDomain) > 128 || !strings.HasSuffix(options.InitialDomain, ".onmicrosoft.com") {
		return false
	}
	label := strings.TrimSuffix(options.InitialDomain, ".onmicrosoft.com")
	if len(label) < 1 || len(label) > 63 || strings.HasPrefix(label, "-") || strings.HasSuffix(label, "-") {
		return false
	}
	for _, character := range label {
		if character != '-' && (character < 'a' || character > 'z') && (character < '0' || character > '9') {
			return false
		}
	}
	seen := make(map[string]bool)
	for _, id := range options.WorkforceTenantIDs {
		if !operationIDPattern.MatchString(id) || id != strings.ToLower(id) || id == options.TenantID || seen[id] {
			return false
		}
		seen[id] = true
	}
	return true
}

func brokerHTTPClient(ctx context.Context) *http.Client {
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
		return fmt.Errorf("broker directory redirects are disabled")
	}
	return client
}

func newBrokerDirectoryReader(ctx context.Context, options brokerDirectoryOptions) (*brokerDirectoryReader, error) {
	if !validBrokerDirectoryOptions(options) {
		return nil, protocolError(400, "invalid_identity_configuration")
	}
	client := brokerHTTPClient(ctx)
	settings := azcore.ClientOptions{Transport: client, Cloud: cloud.AzurePublic}
	managed, err := azidentity.NewManagedIdentityCredential(&azidentity.ManagedIdentityCredentialOptions{
		ID: azidentity.ClientID(options.ManagedIdentityClientID), ClientOptions: settings,
	})
	if err != nil {
		return nil, protocolError(503, "identity_binding_unavailable")
	}
	assertion := func(ctx context.Context) (string, error) {
		token, err := managed.GetToken(ctx, policy.TokenRequestOptions{Scopes: []string{"api://AzureADTokenExchange/.default"}})
		if err != nil || token.Token == "" || !token.ExpiresOn.After(time.Now()) {
			return "", protocolError(503, "identity_binding_unavailable")
		}
		return token.Token, nil
	}
	credential, err := azidentity.NewClientAssertionCredential(options.TenantID, options.ReaderClientID, assertion,
		&azidentity.ClientAssertionCredentialOptions{ClientOptions: settings})
	if err != nil {
		return nil, protocolError(503, "identity_binding_unavailable")
	}
	return newBrokerDirectoryReaderWithCredential(ctx, options, credential)
}

func newBrokerDirectoryReaderWithCredential(ctx context.Context, options brokerDirectoryOptions, credential azcore.TokenCredential) (*brokerDirectoryReader, error) {
	if !validBrokerDirectoryOptions(options) || credential == nil {
		return nil, protocolError(400, "invalid_identity_configuration")
	}
	options.WorkforceTenantIDs = append([]string(nil), options.WorkforceTenantIDs...)
	issuers := make(map[string]bool)
	for _, source := range options.WorkforceTenantIDs {
		issuers["https://login.microsoftonline.com/"+source+"/v2.0/"+options.TenantID] = true
	}
	return &brokerDirectoryReader{credential: credential, client: brokerHTTPClient(ctx), options: options, issuers: issuers}, nil
}

func (r *brokerDirectoryReader) lookup(ctx context.Context, objectID string) (verifiedBrokerBinding, error) {
	if !operationIDPattern.MatchString(objectID) || objectID != strings.ToLower(objectID) {
		return verifiedBrokerBinding{}, protocolError(401, "identity_binding_required")
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	unavailable := func() (verifiedBrokerBinding, error) {
		if err := ctx.Err(); err != nil {
			return verifiedBrokerBinding{}, err
		}
		return verifiedBrokerBinding{}, protocolError(503, "identity_binding_unavailable")
	}
	token, err := r.credential.GetToken(ctx, policy.TokenRequestOptions{Scopes: []string{"https://graph.microsoft.com/.default"}})
	if err != nil || token.Token == "" || len(token.Token) > 32768 || strings.ContainsAny(token.Token, "\r\n\t ") ||
		!token.ExpiresOn.After(time.Now()) {
		return unavailable()
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet,
		"https://graph.microsoft.com/v1.0/users/"+objectID+"?$select=id,accountEnabled,identities", nil)
	if err != nil {
		return unavailable()
	}
	request.Header.Set("Authorization", "Bearer "+token.Token)
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Cache-Control", "no-store")
	response, err := r.client.Do(request)
	if err != nil {
		return unavailable()
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusNotFound {
		return verifiedBrokerBinding{}, protocolError(401, "identity_binding_inactive")
	}
	if response.StatusCode != http.StatusOK {
		return unavailable()
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, maxBrokerProfileBytes+1))
	if err != nil || len(body) > maxBrokerProfileBytes || validateJSON(body) != nil {
		return unavailable()
	}
	var profile brokerProfile
	decoder := json.NewDecoder(bytes.NewReader(body))
	if decoder.Decode(&profile) != nil || profile.ID != objectID || profile.AccountEnabled == nil || profile.Identities == nil ||
		len(profile.Identities) < 1 || len(profile.Identities) > 16 {
		return unavailable()
	}
	if !*profile.AccountEnabled {
		return verifiedBrokerBinding{}, protocolError(401, "identity_binding_inactive")
	}
	var binding *brokerProfileIdentity
	generatedUPNs := 0
	for index := range profile.Identities {
		identity := &profile.Identities[index]
		if !validIdentityText(identity.Issuer, 512) || !validIdentityText(identity.IssuerAssignedID, 512) {
			return unavailable()
		}
		switch identity.SignInType {
		case "userPrincipalName":
			generatedUPNs++
			if generatedUPNs > 1 || identity.Issuer != r.options.InitialDomain {
				return verifiedBrokerBinding{}, protocolError(401, "identity_binding_changed")
			}
		case "federated":
			if binding != nil || !r.issuers[identity.Issuer] ||
				!operationIDPattern.MatchString(identity.IssuerAssignedID) || identity.IssuerAssignedID != strings.ToLower(identity.IssuerAssignedID) {
				return verifiedBrokerBinding{}, protocolError(401, "identity_binding_changed")
			}
			binding = identity
		default:
			return verifiedBrokerBinding{}, protocolError(401, "identity_binding_changed")
		}
	}
	if binding == nil {
		return verifiedBrokerBinding{}, protocolError(401, "identity_binding_required")
	}
	return verifiedBrokerBinding{
		ObjectID: objectID, Issuer: binding.Issuer, Subject: binding.IssuerAssignedID,
		Fingerprint: namespacedID("broker-binding-v1", r.options.TenantID, objectID, binding.Issuer, binding.IssuerAssignedID),
	}, nil
}

func (r *brokerDirectoryReader) reverify(ctx context.Context, expected verifiedBrokerBinding) error {
	if !accountIDPattern.MatchString(expected.Fingerprint) ||
		expected.Fingerprint != namespacedID("broker-binding-v1", r.options.TenantID, expected.ObjectID, expected.Issuer, expected.Subject) {
		return protocolError(503, "identity_binding_unavailable")
	}
	current, err := r.lookup(ctx, expected.ObjectID)
	if err != nil {
		return err
	}
	if current != expected {
		return protocolError(401, "identity_binding_changed")
	}
	return nil
}
