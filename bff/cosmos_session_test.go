package syncbff

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

func TestCosmosPhysicalQueryPagesPreserveObservedDataMinimum(t *testing.T) {
	for _, failSecondPage := range []bool{false, true} {
		name := "continuation"
		if failSecondPage {
			name = "service_error"
		}
		t.Run(name, func(t *testing.T) {
			queryCalls := 0
			store := testCosmos(t, func(request *http.Request) (*http.Response, error) {
				if request.URL.Path == "" || request.URL.Path == "/" {
					return cosmosResponse(request, 200, `{"readableLocations":[{"name":"Test","databaseAccountEndpoint":"https://cosmos.test"}],"writableLocations":[{"name":"Test","databaseAccountEndpoint":"https://cosmos.test"}],"enableMultipleWriteLocations":false,"userConsistencyPolicy":{"defaultConsistencyLevel":"Session"}}`, ""), nil
				}
				if strings.HasSuffix(request.URL.Path, "/docs/head") {
					body, _ := encodeJSON(storedItem{ID: "head", ScopeID: "scope", Kind: "head", Sequence: 2})
					return cosmosResponse(request, 200, string(body), "0:-1#5"), nil
				}
				queryCalls++
				wantToken := "0:-1#5"
				if queryCalls == 2 {
					wantToken = "0:-1#10"
					if request.Header.Get("x-ms-continuation") != "next-page" {
						t.Fatal("physical second page omitted continuation")
					}
				}
				if request.Method != http.MethodPost || queryCalls > 2 || request.Header.Get("x-ms-session-token") != wantToken {
					t.Fatalf("physical query %d minimum got %q want %q", queryCalls, request.Header.Get("x-ms-session-token"), wantToken)
				}
				if queryCalls == 2 && failSecondPage {
					return cosmosResponse(request, 503, `{"code":"ServiceUnavailable","message":"transient"}`, "0:-1#11"), nil
				}
				documents := []storedItem{}
				if !failSecondPage {
					sequence := int64(queryCalls)
					documents = append(documents, storedItem{ID: "change", ScopeID: "scope", Kind: "change", Sequence: sequence, Document: &Document{ID: "note", Version: sequence, Data: json.RawMessage(`{"title":"accepted"}`)}})
				}
				body, _ := encodeJSON(map[string]any{"Documents": documents, "_count": len(documents)})
				response := cosmosResponse(request, 200, string(body), "0:-1#11")
				if queryCalls == 1 {
					response.Header.Set("x-ms-session-token", "0:-1#10")
					response.Header.Set("x-ms-continuation", "next-page")
				}
				return response, nil
			})
			page, session, err := store.Sync(context.Background(), "scope", 0, 2, "0:-1#5")
			if queryCalls != 2 || session != "0:-1#11" {
				t.Fatalf("final observed minimum lost: calls=%d token=%q err=%v", queryCalls, session, err)
			}
			if failSecondPage {
				if err == nil || len(page.Changes) != 0 {
					t.Fatalf("service error exposed partial data: page=%+v err=%v", page, err)
				}
			} else if err != nil || len(page.Changes) != 2 || page.Sequence != 2 {
				t.Fatalf("continued journal wrong: page=%+v err=%v", page, err)
			}
		})
	}
}
