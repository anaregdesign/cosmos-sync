package syncbff

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"regexp"
	"strings"
)

const MaxBodyBytes = 524288
const MaxDocumentBytes = 262144
const MaxSequence int64 = 9007199254740991 // JSON/Dart-web exact integer ceiling.

type Document struct {
	ID      string          `json:"id"`
	Data    json.RawMessage `json:"data"`
	Version int64           `json:"version"`
	Deleted bool            `json:"deleted"`
}
type Mutation struct {
	OperationID string          `json:"operationId"`
	DocumentID  string          `json:"documentId"`
	Kind        string          `json:"kind"`
	Data        json.RawMessage `json:"data"`
	BaseVersion int64           `json:"baseVersion"`
}
type StorePage struct {
	Changes  []Document
	Sequence int64
	HasMore  bool
}
type Store interface {
	Mutate(context.Context, string, Mutation, string, string) (Document, string, error)
	Sync(context.Context, string, int64, int, string) (StorePage, string, error)
}
type ProtocolError struct {
	Status     int
	Code       string
	Current    *Document
	RetryAfter string
}

func (e *ProtocolError) Error() string            { return e.Code }
func protocolError(status int, code string) error { return &ProtocolError{Status: status, Code: code} }

var documentIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$`)
var operationIDPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func validateMutation(m *Mutation, scope string) (string, error) {
	if !documentIDPattern.MatchString(m.DocumentID) || !operationIDPattern.MatchString(m.OperationID) || m.BaseVersion < 0 || m.BaseVersion > MaxSequence {
		return "", protocolError(400, "invalid_mutation")
	}
	m.OperationID = strings.ToLower(m.OperationID)
	var data any
	if m.Kind == "put" {
		decoder := json.NewDecoder(bytes.NewReader(m.Data))
		decoder.UseNumber()
		if decoder.Decode(&data) != nil {
			return "", protocolError(400, "invalid_mutation")
		}
		if _, ok := data.(map[string]any); !ok {
			return "", protocolError(400, "invalid_mutation")
		}
		canonicalData, err := encodeJSON(data)
		if err != nil || len(canonicalData) > MaxDocumentBytes {
			return "", protocolError(400, "document_too_large")
		}
		m.Data = canonicalData
	} else if m.Kind == "delete" {
		if len(m.Data) > 0 && !bytes.Equal(bytes.TrimSpace(m.Data), []byte("null")) {
			return "", protocolError(400, "invalid_mutation")
		}
		m.Data = nil
	} else {
		return "", protocolError(400, "invalid_mutation")
	}
	// Go's JSON encoder sorts map keys. Numeric spellings remain significant.
	canonical, err := encodeJSON([]any{scope, m.DocumentID, m.Kind, m.BaseVersion, data})
	if err != nil {
		return "", err
	}
	hash := sha256.Sum256(canonical)
	return hex.EncodeToString(hash[:]), nil
}

func encodeJSON(value any) ([]byte, error) {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	err := encoder.Encode(value)
	return bytes.TrimSuffix(buffer.Bytes(), []byte("\n")), err
}

// Reject duplicate JSON keys at every nesting level before decoding into structs/maps.
func validateJSON(data []byte) error {
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	var walk func(int) error
	walk = func(depth int) error {
		if depth > 64 {
			return errors.New("JSON depth limit")
		}
		token, err := d.Token()
		if err != nil {
			return err
		}
		if delimiter, ok := token.(json.Delim); ok {
			switch delimiter {
			case '{':
				seen := map[string]bool{}
				for d.More() {
					k, e := d.Token()
					if e != nil {
						return e
					}
					key, ok := k.(string)
					if !ok || seen[key] {
						return errors.New("duplicate key")
					}
					seen[key] = true
					if e = walk(depth + 1); e != nil {
						return e
					}
				}
			case '[':
				for d.More() {
					if e := walk(depth + 1); e != nil {
						return e
					}
				}
			default:
				return errors.New("unexpected delimiter")
			}
			_, err = d.Token()
			return err
		}
		return nil
	}
	if err := walk(0); err != nil {
		return err
	}
	if _, err := d.Token(); err != io.EOF {
		return errors.New("trailing JSON")
	}
	return nil
}
