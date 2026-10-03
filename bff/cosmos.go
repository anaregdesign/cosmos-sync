package syncbff

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/streaming"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/Azure/azure-sdk-for-go/sdk/data/azcosmos"
)

type CosmosConfig struct {
	Endpoint          string `json:"endpoint"`
	Database          string `json:"database"`
	Container         string `json:"container"`
	SingleWriteRegion bool   `json:"singleWriteRegion"`
}

// CosmosStore only connects to an existing container; it never provisions resources.
type CosmosStore struct {
	container *azcosmos.ContainerClient
	client    *azcosmos.Client
	retention retentionControls
}
type storedItem struct {
	ID                     string                `json:"id"`
	ScopeID                string                `json:"scopeId"`
	Kind                   string                `json:"kind"`
	Sequence               int64                 `json:"sequence,omitempty"`
	Document               *Document             `json:"document,omitempty"`
	RequestHash            string                `json:"requestHash,omitempty"`
	EstimatedRetainedBytes int64                 `json:"estimatedRetainedBytes,omitempty"`
	Account                *accountRecord        `json:"account,omitempty"`
	Policy                 *AuthorizationPolicy  `json:"policy,omitempty"`
	Audit                  *authorizationAudit   `json:"audit,omitempty"`
	AuthorizationReceipt   *authorizationReceipt `json:"authorizationReceipt,omitempty"`
}

func NewCosmosStore(ctx context.Context, c CosmosConfig) (*CosmosStore, error) {
	if !strings.HasPrefix(c.Endpoint, "https://") || c.Database == "" || c.Container == "" || !c.SingleWriteRegion {
		return nil, fmt.Errorf("Cosmos requires HTTPS endpoint, database, container, and an operator-confirmed single-write-region account")
	}
	credential, err := azidentity.NewDefaultAzureCredential(nil)
	if err != nil {
		return nil, err
	}
	client, err := azcosmos.NewClient(c.Endpoint, credential, &azcosmos.ClientOptions{ClientOptions: azcore.ClientOptions{PerCallPolicies: []policy.Policy{batchWirePolicy{}, accountGuard{}}}})
	if err != nil {
		return nil, err
	}
	container, err := client.NewContainer(c.Database, c.Container)
	if err != nil {
		client.Close()
		return nil, err
	}
	response, err := container.Read(ctx, nil)
	if err != nil {
		client.Close()
		return nil, err
	}
	properties := response.ContainerProperties
	if properties == nil || len(properties.PartitionKeyDefinition.Paths) != 1 || properties.PartitionKeyDefinition.Paths[0] != "/scopeId" {
		client.Close()
		return nil, fmt.Errorf("container partition key must be /scopeId")
	}
	if ttl := properties.DefaultTimeToLive; ttl != nil && *ttl != -1 {
		client.Close()
		return nil, fmt.Errorf("journal and receipts require a container without default expiry")
	}
	return &CosmosStore{container: container, client: client}, nil
}

// The pinned official SDK's outer batch encoder HTML-escapes raw item JSON. Keep
// JSON string semantics but remove that avoidable sixfold expansion before send.
// Cosmos request authentication does not sign the body. SetBody preserves retries.
type batchWirePolicy struct{}

func (batchWirePolicy) Do(request *policy.Request) (*http.Response, error) {
	if !strings.EqualFold(request.Raw().Header.Get("x-ms-cosmos-is-batch-request"), "true") {
		return request.Next()
	}
	body, err := io.ReadAll(io.LimitReader(request.Raw().Body, 8*1024*1024+1))
	if err != nil {
		return nil, err
	}
	if len(body) > 8*1024*1024 {
		return nil, protocolError(400, "document_too_large")
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	var value any
	if err = decoder.Decode(&value); err != nil {
		return nil, err
	}
	compact, err := encodeJSON(value)
	if err != nil {
		return nil, err
	}
	if len(compact) > 2*1024*1024 {
		return nil, protocolError(400, "document_too_large")
	}
	if err = request.SetBody(streaming.NopCloser(bytes.NewReader(compact)), "application/json"); err != nil {
		return nil, err
	}
	return request.Next()
}

// Validate the account metadata already fetched by the official SDK. This policy
// performs no extra requests and also checks subsequent SDK metadata refreshes.
type accountGuard struct{}

func (accountGuard) Do(request *policy.Request) (*http.Response, error) {
	response, err := request.Next()
	path := request.Raw().URL.Path
	if err != nil || response == nil || response.StatusCode != 200 || request.Raw().Method != http.MethodGet || (path != "" && path != "/") {
		return response, err
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 1048577))
	_ = response.Body.Close()
	if err != nil {
		return nil, err
	}
	if len(body) > 1048576 {
		return nil, fmt.Errorf("Cosmos account metadata exceeds limit")
	}
	response.Body = io.NopCloser(bytes.NewReader(body))
	var account struct {
		MultipleWrites *bool             `json:"enableMultipleWriteLocations"`
		Writes         []json.RawMessage `json:"writableLocations"`
		Consistency    struct {
			Level string `json:"defaultConsistencyLevel"`
		} `json:"userConsistencyPolicy"`
	}
	if json.Unmarshal(body, &account) != nil || account.MultipleWrites == nil || *account.MultipleWrites || len(account.Writes) == 0 {
		return nil, fmt.Errorf("Cosmos Sync requires explicit single-write mode and writable account metadata")
	}
	if account.Consistency.Level != "Session" && account.Consistency.Level != "Strong" && account.Consistency.Level != "BoundedStaleness" {
		return nil, fmt.Errorf("Cosmos Sync requires Session or stronger account consistency")
	}
	return response, nil
}
func (s *CosmosStore) Close() { s.client.Close() }
func (s *CosmosStore) ConfigureRetention(options RetentionOptions) error {
	return s.retention.configure(options)
}

func (s *CosmosStore) read(ctx context.Context, scope, id, session string) (*storedItem, azcore.ETag, string, error) {
	response, err := s.container.ReadItem(ctx, azcosmos.NewPartitionKeyString(scope), id, &azcosmos.ItemOptions{SessionToken: stringPointer(session), ConsistencyLevel: azcosmos.ConsistencyLevelSession.ToPtr()})
	session = nextSession(session, response.RawResponse)
	if err != nil {
		var service *azcore.ResponseError
		if errors.As(err, &service) {
			session = nextSession(session, service.RawResponse)
			if service.StatusCode == 404 {
				return nil, "", session, nil
			}
		}
		return nil, "", session, cosmosError(err)
	}
	var item storedItem
	if err := json.Unmarshal(response.Value, &item); err != nil {
		return nil, "", session, err
	}
	return &item, response.ETag, session, nil
}

func (s *CosmosStore) Mutate(ctx context.Context, scope string, m Mutation, hash, session string) (Document, string, error) {
	if m.AuthorizationVersion != "" {
		ctx = withAuthorizationSessions(ctx)
	}
	pk := azcosmos.NewPartitionKeyString(scope)
	receiptID := "r:" + mutationReceiptKey(m)
	for attempt := 0; attempt < 12; attempt++ {
		var authorizationPolicy *AuthorizationPolicy
		var authorizationETag azcore.ETag
		if m.AuthorizationVersion != "" {
			// Authorization and data maintain separate opaque session minima.
			// A policy read must never downgrade the caller's validated data token.
			policy, etag, err := s.readAuthorizationPolicyAt(ctx, scope, session)
			if err != nil {
				return Document{}, session, err
			}
			if err := checkAuthorizationWrite(policy, scope, m); err != nil {
				return Document{}, session, err
			}
			authorizationPolicy, authorizationETag = policy, etag
		}
		receipt, _, token, err := s.read(ctx, scope, receiptID, session)
		session = token
		if err != nil {
			return Document{}, session, err
		}
		if receipt != nil {
			if receipt.RequestHash != hash {
				return Document{}, session, protocolError(409, "idempotency_mismatch")
			}
			if receipt.Document == nil {
				return Document{}, session, protocolError(503, "corrupt_receipt")
			}
			return *receipt.Document, session, nil
		}
		head, headETag, token, err := s.read(ctx, scope, "head", session)
		session = token
		if err != nil {
			return Document{}, session, err
		}
		current, docETag, token, err := s.read(ctx, scope, "d:"+m.DocumentID, session)
		session = token
		if err != nil {
			return Document{}, session, err
		}
		var currentDoc *Document
		if current != nil {
			currentDoc = current.Document
			if currentDoc == nil {
				return Document{}, session, protocolError(503, "corrupt_document")
			}
		}
		var base int64
		if currentDoc != nil {
			base = currentDoc.Version
		}
		if base != m.BaseVersion {
			// The receipt404 and document read are not one snapshot. An overlapping
			// retry may have committed this very operation while these reads ran.
			replay, _, token, err := s.read(ctx, scope, receiptID, session)
			session = token
			if err != nil {
				return Document{}, session, err
			}
			if replay != nil {
				if replay.RequestHash != hash {
					return Document{}, session, protocolError(409, "idempotency_mismatch")
				}
				if replay.Document == nil {
					return Document{}, session, protocolError(503, "corrupt_receipt")
				}
				return *replay.Document, session, nil
			}
			return Document{}, session, &ProtocolError{Status: 409, Code: "conflict", Current: currentDoc}
		}
		var sequence int64
		if head != nil {
			sequence = head.Sequence
		}
		if sequence >= MaxSequence {
			return Document{}, session, protocolError(503, "sequence_exhausted")
		}
		sequence++
		document := Document{ID: m.DocumentID, Data: m.Data, Version: sequence, Deleted: m.Kind == "delete"}
		var retainedBytes int64
		if head != nil {
			retainedBytes = head.EstimatedRetainedBytes
			if retainedBytes == 0 && head.Sequence > 0 {
				retainedBytes = legacyRetainedEstimate(head.Sequence)
			}
		}
		addition := retainedEstimate(document)
		if !s.retention.allows(sequence-1, retainedBytes, addition) {
			return Document{}, session, capacityError()
		}
		headBody, _ := encodeJSON(storedItem{ID: "head", ScopeID: scope, Kind: "head", Sequence: sequence, EstimatedRetainedBytes: retainedBytes + addition})
		docBody, _ := encodeJSON(storedItem{ID: "d:" + m.DocumentID, ScopeID: scope, Kind: "document", Document: &document})
		changeBody, _ := encodeJSON(storedItem{ID: fmt.Sprintf("c:%016d", sequence), ScopeID: scope, Kind: "change", Sequence: sequence, Document: &document})
		receiptBody, _ := encodeJSON(storedItem{ID: receiptID, ScopeID: scope, Kind: "receipt", RequestHash: hash, Document: &document})
		batch := s.container.NewTransactionalBatch(pk)
		if head == nil {
			batch.CreateItem(headBody, nil)
		} else {
			batch.ReplaceItem("head", headBody, &azcosmos.TransactionalBatchItemOptions{IfMatchETag: &headETag})
		}
		if current == nil {
			batch.CreateItem(docBody, nil)
		} else {
			batch.ReplaceItem("d:"+m.DocumentID, docBody, &azcosmos.TransactionalBatchItemOptions{IfMatchETag: &docETag})
		}
		batch.CreateItem(changeBody, nil)
		batch.CreateItem(receiptBody, nil)
		operationCount := 4
		if authorizationPolicy != nil {
			// Replacing the unchanged policy with If-Match is an atomic fence,
			// not a permission update. A successful revoke changes this ETag; no
			// batch authorized against the old policy can subsequently commit.
			body, _ := encodeJSON(storedItem{ID: authorizationPolicyItemID, ScopeID: scope, Kind: "authorization", Policy: authorizationPolicy})
			batch.ReplaceItem(authorizationPolicyItemID, body, &azcosmos.TransactionalBatchItemOptions{IfMatchETag: &authorizationETag})
			operationCount++
		}
		response, err := s.container.ExecuteTransactionalBatch(ctx, batch, &azcosmos.TransactionalBatchOptions{SessionToken: session, ConsistencyLevel: azcosmos.ConsistencyLevelSession.ToPtr()})
		session = nextSession(session, response.RawResponse)
		if err != nil {
			var service *azcore.ResponseError
			if errors.As(err, &service) {
				session = nextSession(session, service.RawResponse)
				if service.StatusCode == 409 || service.StatusCode == 412 {
					continue
				}
			}
			return Document{}, session, cosmosError(err)
		}
		status := batchStatusForOperations(response, operationCount)
		if status == 200 {
			return document, session, nil
		}
		if status == 409 || status == 412 {
			continue
		}
		if status == 429 {
			return Document{}, session, &ProtocolError{Status: 429, Code: "rate_limited", RetryAfter: "1"}
		}
		return Document{}, session, protocolError(503, "batch_failed")
	}
	return Document{}, session, &ProtocolError{Status: 503, Code: "contention_retry", RetryAfter: "1"}
}

func (s *CosmosStore) Sync(ctx context.Context, scope string, after int64, limit int, session string) (StorePage, string, error) {
	head, _, token, err := s.read(ctx, scope, "head", session)
	session = token
	if err != nil {
		return StorePage{}, session, err
	}
	var headSequence int64
	if head != nil {
		headSequence = head.Sequence
	}
	// A valid cursor can be newer than a lagging replica; never discard it on that evidence.
	if after > headSequence {
		return StorePage{}, session, &ProtocolError{Status: 503, Code: "sync_gap_retry", RetryAfter: "1"}
	}
	crossPartition := false
	// The pinned SDK shallow-copies QueryOptions and only updates continuation.
	// Keep the pointed-to value live so each physical page honors the preceding
	// page's opaque consistency minimum, including empty pages.
	querySession := session
	pager := s.container.NewQueryItemsPager("SELECT TOP @count * FROM c WHERE c.kind = 'change' AND c.sequence > @after ORDER BY c.sequence", azcosmos.NewPartitionKeyString(scope), &azcosmos.QueryOptions{
		SessionToken: &querySession, ConsistencyLevel: azcosmos.ConsistencyLevelSession.ToPtr(), PageSizeHint: int32(limit + 1), EnableCrossPartitionQuery: &crossPartition,
		QueryParameters: []azcosmos.QueryParameter{{Name: "@count", Value: limit + 1}, {Name: "@after", Value: after}},
	})
	documents := []Document{}
	for pager.More() && len(documents) < limit+1 {
		response, err := pager.NextPage(ctx)
		session = nextSession(session, response.RawResponse)
		querySession = session
		if err != nil {
			// The SDK returns a zero query response on service errors; their
			// observed minimum remains on ResponseError.RawResponse instead.
			var service *azcore.ResponseError
			if errors.As(err, &service) {
				session = nextSession(session, service.RawResponse)
			}
			return StorePage{}, session, cosmosError(err)
		}
		for _, value := range response.Items {
			var item storedItem
			if json.Unmarshal(value, &item) != nil || item.Document == nil {
				return StorePage{}, session, protocolError(503, "corrupt_journal")
			}
			if item.Sequence != after+int64(len(documents))+1 || item.Document.Version != item.Sequence {
				return StorePage{}, session, &ProtocolError{Status: 503, Code: "sync_gap_retry", RetryAfter: "1"}
			}
			documents = append(documents, *item.Document)
		}
	}
	if len(documents) == 0 && headSequence > after {
		return StorePage{}, session, &ProtocolError{Status: 503, Code: "sync_gap_retry", RetryAfter: "1"}
	}
	page := StorePage{Changes: documents, Sequence: after, HasMore: len(documents) > limit}
	if page.HasMore {
		page.Changes = documents[:limit]
	}
	if len(page.Changes) > 0 {
		page.Sequence = page.Changes[len(page.Changes)-1].Version
	}
	return page, session, nil
}

func batchStatus(response azcosmos.TransactionalBatchResponse) int {
	return batchStatusForOperations(response, 4)
}

func batchStatusForOperations(response azcosmos.TransactionalBatchResponse, count int) int {
	for _, result := range response.OperationResults {
		if result.StatusCode >= 200 && result.StatusCode < 300 || result.StatusCode == 424 {
			continue
		}
		return int(result.StatusCode)
	}
	if !response.Success || len(response.OperationResults) != count {
		return 503
	}
	for _, result := range response.OperationResults {
		if result.StatusCode == 424 {
			return 503
		}
	}
	return 200
}
func stringPointer(value string) *string {
	if value == "" {
		return nil
	}
	return &value
}
func nextSession(previous string, response *http.Response) string {
	if response != nil {
		if token := response.Header.Get("x-ms-session-token"); token != "" {
			return token
		}
	}
	return previous
}
func cosmosError(err error) error {
	var service *azcore.ResponseError
	if errors.As(err, &service) && service.StatusCode == 429 {
		retry := "1"
		if service.RawResponse != nil {
			if milliseconds, e := strconv.ParseFloat(service.RawResponse.Header.Get("x-ms-retry-after-ms"), 64); e == nil {
				retry = strconv.Itoa(max(1, int(milliseconds/1000)+1))
			}
		}
		return &ProtocolError{Status: 429, Code: "rate_limited", RetryAfter: retry}
	}
	return err
}
