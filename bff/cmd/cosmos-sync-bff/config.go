package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"

	syncbff "github.com/anaregdesign/cosmos-sync/bff"
)

const maxConfigBytes = 1024 * 1024

func readConfiguration(path string, explicitFile bool, lookup func(string) (string, bool)) (syncbff.Config, error) {
	var cfg syncbff.Config
	value, fromEnv := lookup("COSMOS_SYNC_CONFIG_JSON")
	var data []byte
	if fromEnv {
		if explicitFile {
			return cfg, errors.New("select either config file or COSMOS_SYNC_CONFIG_JSON")
		}
		if len(value) > maxConfigBytes {
			return cfg, errors.New("configuration exceeds size limit")
		}
		data = []byte(value)
	} else {
		file, err := os.Open(path)
		if err != nil {
			return cfg, errors.New("cannot read configuration")
		}
		defer file.Close()
		data, err = io.ReadAll(io.LimitReader(file, maxConfigBytes+1))
		if err != nil || len(data) > maxConfigBytes {
			return cfg, errors.New("cannot read configuration within size limit")
		}
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&cfg) != nil {
		return syncbff.Config{}, errors.New("invalid configuration")
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		return syncbff.Config{}, errors.New("invalid configuration")
	}
	return cfg, nil
}
