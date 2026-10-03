package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func configEnv(value string, present bool) func(string) (string, bool) {
	return func(string) (string, bool) { return value, present }
}

func TestConfigurationEnvironmentDoesNotRequireFile(t *testing.T) {
	cfg, err := readConfiguration("missing.json", false, configEnv(`{"storage":"cosmos","listen":":8080","development":false}`, true))
	if err != nil || cfg.Storage != "cosmos" || cfg.Listen != ":8080" || cfg.Development {
		t.Fatal("valid environment configuration was not loaded")
	}
	if _, err = readConfiguration("missing.json", true, configEnv(`{}`, true)); err == nil {
		t.Fatal("ambiguous file and environment source accepted")
	}
}

func TestConfigurationRejectsInvalidOrLargeEnvironmentWithoutValues(t *testing.T) {
	secret := "never-print-this-secret"
	for _, value := range []string{"", `{`, `{"unknown":"` + secret + `"}`, `{} {}`, `{"tlsMode":"container-apps"}`, strings.Repeat(secret, maxConfigBytes/len(secret)+1)} {
		_, err := readConfiguration("missing.json", false, configEnv(value, true))
		if err == nil || strings.Contains(err.Error(), secret) || strings.Contains(err.Error(), value) && value != "" {
			t.Fatalf("invalid source should fail with a fixed redacted error: %q", err)
		}
	}
}

func TestConfigurationFileCompatibilityAndBound(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, []byte(`{"grantsFile":"/run/config/grants.json","grants":[]}`), 0600); err != nil {
		t.Fatal(err)
	}
	cfg, err := readConfiguration(path, true, configEnv("", false))
	if err != nil || cfg.GrantsFile != "/run/config/grants.json" {
		t.Fatal("file configuration no longer works")
	}
	if err := os.WriteFile(path, []byte(strings.Repeat(" ", maxConfigBytes+1)), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := readConfiguration(path, false, configEnv("", false)); err == nil {
		t.Fatal("unbounded configuration file accepted")
	}
	if _, err := readConfiguration(filepath.Join(t.TempDir(), "missing"), false, configEnv("", false)); err == nil {
		t.Fatal("missing file accepted")
	}
}
