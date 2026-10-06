package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"

	syncbff "github.com/anaregdesign/cosmos-sync/bff"
)

func runFreshProof(ctx context.Context, opts options, input io.Reader) error {
	if !opts.FreshProofStdin || opts.OwnerFile == "" || opts.ReceiptFile == "" ||
		opts.DirectoryConfigFile == "" || opts.Callback == "" || opts.TokenFile != "" ||
		opts.OutputDir != "" || opts.PermissionVersion != "" {
		return code("invalid_arguments")
	}
	ownerBytes, err := readPrivateFile(opts.OwnerFile, 65536)
	if err != nil {
		return code("owner_file_rejected")
	}
	receiptBytes, err := readPrivateFile(opts.ReceiptFile, 65536)
	if err != nil {
		return code("receipt_file_rejected")
	}
	var owner ownerRecord
	var receipt registrationReceipt
	if json.Unmarshal(ownerBytes, &owner) != nil || json.Unmarshal(receiptBytes, &receipt) != nil ||
		validateConfiguration(owner, receipt) != nil {
		return code("configuration_rejected")
	}
	configBytes, err := readPrivateFile(opts.DirectoryConfigFile, 65536)
	if err != nil {
		return code("configuration_rejected")
	}
	var config syncbff.Config
	decoder := json.NewDecoder(bytes.NewReader(configBytes))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&config) != nil || decoder.Decode(new(any)) != io.EOF ||
		config.Authorization.Directory == nil || config.Authorization.Mode != "directory" ||
		config.Storage != "cosmos" || config.Development || len(config.Grants) != 0 || config.GrantsFile != "" ||
		config.Authorization.Directory.TenantID != owner.TenantID ||
		config.OIDC.Issuer != receipt.OIDC.Issuer || config.OIDC.Audience != receipt.OIDC.Audience ||
		config.OIDC.RequiredScope != requiredScope || config.OIDC.TokenUse != "" ||
		len(config.OIDC.AllowedClientIDs) != 1 || config.OIDC.AllowedClientIDs[0] != receipt.Native.AppID {
		return code("configuration_rejected")
	}
	proofBytes, err := io.ReadAll(io.LimitReader(input, 65537))
	if err != nil || len(proofBytes) > 65536 {
		return code("fresh_proof_rejected")
	}
	proof := make(map[string]string, 3)
	decoder = json.NewDecoder(bytes.NewReader(proofBytes))
	if delimiter, err := decoder.Token(); err != nil || delimiter != json.Delim('{') {
		return code("fresh_proof_rejected")
	}
	for decoder.More() {
		key, err := decoder.Token()
		name, ok := key.(string)
		if err != nil || !ok || (name != "challenge" && name != "accessToken" && name != "idToken") {
			return code("fresh_proof_rejected")
		}
		if _, duplicate := proof[name]; duplicate {
			return code("fresh_proof_rejected")
		}
		var value string
		if decoder.Decode(&value) != nil {
			return code("fresh_proof_rejected")
		}
		proof[name] = value
	}
	if delimiter, err := decoder.Token(); err != nil || delimiter != json.Delim('}') ||
		decoder.Decode(new(any)) != io.EOF || len(proof) != 3 {
		return code("fresh_proof_rejected")
	}
	return syncbff.VerifyFreshBrokerAuthentication(ctx, config, opts.Callback, proof["challenge"],
		owner.OwnerObjectID, proof["accessToken"], proof["idToken"])
}
