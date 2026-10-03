package syncbff

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestDocumentNumbersSafeAcrossNativeAndWeb(t *testing.T) {
	for _, data := range []string{
		`{"nested":[{"n":9007199254740991},-9007199254740991,1.00,6e0,0e999999]}`,
		`{"small":1e-300,"fraction":0.125}`,
	} {
		mutation := Mutation{OperationID: "11111111-1111-4111-8111-111111111111", DocumentID: "note", Kind: "put", Data: json.RawMessage(data)}
		if _, err := validateMutation(&mutation, "scope"); err != nil {
			t.Fatalf("rejected representable data %s: %v", data, err)
		}
		if strings.Contains(data, "1.00") && !strings.Contains(string(mutation.Data), "1.00") {
			t.Fatal("numeric spelling was changed")
		}
	}
	for _, number := range []string{"9007199254740992", "-9007199254740992", "1e20", "9007199254740992.0", "1e500", "1e-500", "9007199254740991.5", "9007199254740992.1", "100000000000000000000.1", "-9007199254740991.5", "90071992547409915e-1"} {
		t.Run(number, func(t *testing.T) {
			mutation := Mutation{OperationID: "11111111-1111-4111-8111-111111111111", DocumentID: "note", Kind: "put", Data: json.RawMessage(`{"nested":[{"n":` + number + `}]}`)}
			_, err := validateMutation(&mutation, "scope")
			if e, ok := err.(*ProtocolError); !ok || e.Status != 400 || e.Code != "invalid_number" {
				t.Fatalf("unsafe number accepted: %v", err)
			}
		})
	}
}
