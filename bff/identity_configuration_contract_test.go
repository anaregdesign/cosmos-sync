package syncbff

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"reflect"
	"testing"
)

func decodeDirectoryConfiguration(t *testing.T, data []byte) Config {
	t.Helper()
	var config Config
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if len(data) > 1024*1024 || decoder.Decode(&config) != nil || decoder.Decode(new(any)) != io.EOF {
		t.Fatal("generated configuration does not match the strict production schema")
	}
	return config
}

func TestTerraformDirectoryConfigurationContract(t *testing.T) {
	path := os.Getenv("COSMOS_SYNC_TERRAFORM_CONFIG")
	if path == "" {
		t.Skip("run the workload Terraform validator for the generated JSON contract")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal("cannot read the generated mock-plan configuration")
	}
	config := decodeDirectoryConfiguration(t, data)
	targets, err := identityProofTargets(config, config.Authorization.Directory)
	if err != nil || len(targets) != 2 || config.Authorization.Mode != "directory" ||
		config.Storage != "cosmos" || config.Development || len(config.Grants) != 0 || config.GrantsFile != "" ||
		config.CursorKeyBase64 != "" || config.MetricsToken != "" {
		t.Fatal("generated configuration violates the actual directory factory contract")
	}
	example, err := os.ReadFile("config.directory.example.json")
	if err != nil {
		t.Fatal(err)
	}
	expected := decodeDirectoryConfiguration(t, example)
	if !reflect.DeepEqual(config.Authorization, expected.Authorization) || !reflect.DeepEqual(config.OIDC, expected.OIDC) {
		t.Fatal("Terraform output and documented production directory trust diverged")
	}
}

func TestDirectoryConfigurationTrustWithoutNetwork(t *testing.T) {
	data, err := os.ReadFile("config.directory.example.json")
	if err != nil {
		t.Fatal(err)
	}
	config := decodeDirectoryConfiguration(t, data)
	if targets, err := identityProofTargets(config, config.Authorization.Directory); err != nil || len(targets) != 2 {
		t.Fatal("documented production trust rejected")
	}
	for name, mutate := range map[string]func(*Config){
		"missing":      func(c *Config) { c.Authorization.Directory = nil },
		"wrong issuer": func(c *Config) { c.OIDC.Issuer = "https://issuer.invalid/" },
		"wrong tenant": func(c *Config) { c.OIDC.TenantClaim = "tenant" },
		"no client":    func(c *Config) { c.OIDC.AllowedClientIDs = nil },
		"ID audience":  func(c *Config) { c.OIDC.Audience = c.OIDC.AllowedClientIDs[0] },
		"reader as MI": func(c *Config) {
			c.Authorization.Directory.ReaderClientID = c.Authorization.Directory.ManagedIdentityClientID
		},
		"no workforce": func(c *Config) { c.Authorization.Directory.WorkforceTenantIDs = nil },
		"target source": func(c *Config) {
			c.Authorization.Directory.WorkforceTenantIDs = []string{c.Authorization.Directory.TenantID}
		},
		"bad domain":  func(c *Config) { c.Authorization.Directory.InitialDomain = "a.onmicrosoft.com.attacker.invalid" },
		"namespace":   func(c *Config) { c.Authorization.Directory.Namespace = " padded" },
		"no callback": func(c *Config) { c.Authorization.Directory.Callbacks = nil },
		"userinfo":    func(c *Config) { c.Authorization.Directory.Callbacks = []string{"https://user@app.invalid/callback"} },
		"query": func(c *Config) {
			c.Authorization.Directory.Callbacks = []string{"https://app.invalid/callback?extra=1"}
		},
		"duplicate": func(c *Config) {
			c.Authorization.Directory.Callbacks = append(c.Authorization.Directory.Callbacks, c.Authorization.Directory.Callbacks[0])
		},
	} {
		t.Run(name, func(t *testing.T) {
			candidate := decodeDirectoryConfiguration(t, data)
			mutate(&candidate)
			if _, err := identityProofTargets(candidate, candidate.Authorization.Directory); err == nil {
				t.Fatal("invalid trust passed offline factory validation")
			}
		})
	}
}
