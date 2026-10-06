package syncbff

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/data/azcosmos"
)

const authorizationPolicyItemID = "a:policy"
const authorizationAccountItemID = "a:account"

type authorizationSessionsKey struct{}

// This is request-local authorization session state, not a permission cache.
// It is used only by account, policy, audit, receipt and membership operations.
// Data reads/writes keep their separate, caller-supplied session-token chain:
// opaque Cosmos tokens cannot be ordered by choosing one chain over another.
// Tokens never cross partition or leave the BFF.
type authorizationSessions struct {
	mu        sync.Mutex
	tokens    map[string]string
	observed  map[string]observedAuthorizationPolicy
	directory *observedIdentityDirectory
}

// Remember only a security high-water mark, never a cached permission answer.
type observedAuthorizationPolicy struct {
	revision int64
	owner    string
	mode     string
	digest   [32]byte
}

func withAuthorizationSessions(ctx context.Context) context.Context {
	if _, ok := ctx.Value(authorizationSessionsKey{}).(*authorizationSessions); ok {
		return ctx
	}
	return context.WithValue(ctx, authorizationSessionsKey{}, &authorizationSessions{tokens: make(map[string]string), observed: make(map[string]observedAuthorizationPolicy)})
}

func observeAuthorizationPolicy(ctx context.Context, scopeID string, policy *AuthorizationPolicy) error {
	sessions, ok := ctx.Value(authorizationSessionsKey{}).(*authorizationSessions)
	if !ok {
		return nil
	}
	var observation observedAuthorizationPolicy
	if policy != nil {
		if !validAuthorizationPolicy(policy, scopeID) {
			return protocolError(503, "authorization_store_unavailable")
		}
		body, err := encodeJSON(policy)
		if err != nil {
			return protocolError(503, "authorization_store_unavailable")
		}
		observation = observedAuthorizationPolicy{revision: policy.Revision, owner: policy.OwnerAccountID, mode: policy.Mode, digest: sha256.Sum256(body)}
	}
	sessions.mu.Lock()
	defer sessions.mu.Unlock()
	previous, exists := sessions.observed[scopeID]
	if exists && (policy == nil || observation.owner != previous.owner || observation.mode != previous.mode || observation.revision < previous.revision || observation.revision == previous.revision && observation.digest != previous.digest) {
		return protocolError(503, "authorization_store_unavailable")
	}
	if policy == nil {
		return nil
	}
	if !exists && len(sessions.observed) >= 8 {
		return protocolError(503, "authorization_store_unavailable")
	}
	sessions.observed[scopeID] = observation
	return nil
}

func authorizationSession(ctx context.Context, scopeID, supplied string) (string, error) {
	sessions, ok := ctx.Value(authorizationSessionsKey{}).(*authorizationSessions)
	if !ok {
		return supplied, nil
	}
	sessions.mu.Lock()
	defer sessions.mu.Unlock()
	if _, exists := sessions.tokens[scopeID]; !exists && len(sessions.tokens) >= 8 {
		return "", protocolError(503, "authorization_store_unavailable")
	}
	// supplied belongs to this authorization chain, never to the data/session
	// envelope. The holder is its last sequentially observed request response.
	if observed := sessions.tokens[scopeID]; observed != "" {
		return observed, nil
	}
	return supplied, nil
}

func rememberAuthorizationSession(ctx context.Context, scopeID, session string) error {
	sessions, ok := ctx.Value(authorizationSessionsKey{}).(*authorizationSessions)
	if !ok {
		return nil
	}
	sessions.mu.Lock()
	defer sessions.mu.Unlock()
	if _, exists := sessions.tokens[scopeID]; !exists && len(sessions.tokens) >= 8 {
		return protocolError(503, "authorization_store_unavailable")
	}
	sessions.tokens[scopeID] = session
	return nil
}

func (s *CosmosStore) readAuthorizationItem(ctx context.Context, scopeID, id, session string) (*storedItem, azcore.ETag, string, error) {
	session, err := authorizationSession(ctx, scopeID, session)
	if err != nil {
		return nil, "", session, err
	}
	item, etag, session, err := s.read(ctx, scopeID, id, session)
	if rememberErr := rememberAuthorizationSession(ctx, scopeID, session); rememberErr != nil {
		return nil, "", session, rememberErr
	}
	return item, etag, session, err
}

func (s *CosmosStore) authorizationAccount(ctx context.Context, accountID string) (*accountRecord, error) {
	if !accountIDPattern.MatchString(accountID) {
		return nil, protocolError(400, "invalid_authorization_request")
	}
	scopeID := personalScopeID(accountID)
	item, _, session, err := s.readAuthorizationItem(ctx, scopeID, authorizationAccountItemID, "")
	if err != nil {
		return nil, err
	}
	policy, _, session, err := s.readAuthorizationPolicy(ctx, scopeID, session)
	if err != nil {
		return nil, err
	}
	if item == nil && policy != nil {
		// These are two reads, not one snapshot: another BFF can atomically
		// create both records between them. The later token observes its ACK.
		item, _, _, err = s.readAuthorizationItem(ctx, scopeID, authorizationAccountItemID, session)
		if err != nil {
			return nil, err
		}
	}
	if item == nil && policy == nil {
		return nil, nil
	}
	if item == nil || item.ID != authorizationAccountItemID || item.ScopeID != scopeID || item.Kind != "account" ||
		item.Account == nil || !validAccountRecord(*item.Account, accountID) || !validPersonalPolicy(policy, accountID) {
		return nil, protocolError(503, "authorization_store_unavailable")
	}
	return item.Account, nil
}

func (s *CosmosStore) EnsureAccount(ctx context.Context, identity AccountIdentity) (Account, error) {
	if !validAccountIdentity(identity) {
		return Account{}, protocolError(400, "invalid_authorization_request")
	}
	return s.ensureAuthorizationAccount(ctx, accountRecord{Account: identityAccount(identity), Identity: identity})
}

func (s *CosmosStore) ensureDirectoryAccount(ctx context.Context, account directoryAccount) (Account, error) {
	if !validDirectoryAccount(account) {
		return Account{}, protocolError(400, "invalid_authorization_request")
	}
	return s.ensureAuthorizationAccount(ctx, accountRecord{Account: account.Account, DirectoryVersion: directoryAccountVersion})
}

func (s *CosmosStore) ensureAuthorizationAccount(ctx context.Context, record accountRecord) (Account, error) {
	ctx = withAuthorizationSessions(ctx)
	if !validAccountRecord(record, record.AccountID) {
		return Account{}, protocolError(400, "invalid_authorization_request")
	}
	account := record.Account
	for attempt := 0; attempt < 12; attempt++ {
		if err := ctx.Err(); err != nil {
			return Account{}, err
		}
		existing, err := s.authorizationAccount(ctx, account.AccountID)
		if err != nil {
			return Account{}, err
		}
		if existing != nil {
			if *existing != record {
				return Account{}, protocolError(503, "authorization_store_unavailable")
			}
			return account, nil
		}
		policy := newAuthorizationPolicy(account.PersonalScopeID, account.AccountID, "user")
		accountBody, err := encodeJSON(storedItem{ID: authorizationAccountItemID, ScopeID: account.PersonalScopeID, Kind: "account", Account: &record})
		if err != nil {
			return Account{}, protocolError(503, "authorization_store_unavailable")
		}
		policyBody, err := encodeJSON(storedItem{ID: authorizationPolicyItemID, ScopeID: account.PersonalScopeID, Kind: "authorization", Policy: policy})
		if err != nil {
			return Account{}, protocolError(503, "authorization_store_unavailable")
		}
		batch := s.container.NewTransactionalBatch(azcosmos.NewPartitionKeyString(account.PersonalScopeID))
		batch.CreateItem(accountBody, nil)
		batch.CreateItem(policyBody, nil)
		if _, err := s.executeAuthorizationBatch(ctx, account.PersonalScopeID, batch, 2, ""); err != nil {
			if authorizationContention(err) {
				continue
			}
			return Account{}, err
		}
		// Read with the acknowledged batch's token before claiming that the
		// account's personal policy is usable. Partial metadata fails closed.
		verified, err := s.authorizationAccount(ctx, account.AccountID)
		if err != nil {
			return Account{}, err
		}
		if verified == nil || *verified != record {
			return Account{}, protocolError(503, "authorization_store_unavailable")
		}
		return account, nil
	}
	return Account{}, &ProtocolError{Status: 503, Code: "contention_retry", RetryAfter: "1"}
}

func (s *CosmosStore) readAuthorizationPolicy(ctx context.Context, scopeID, session string) (*AuthorizationPolicy, azcore.ETag, string, error) {
	item, etag, session, err := s.readAuthorizationItem(ctx, scopeID, authorizationPolicyItemID, session)
	if err != nil {
		return nil, "", session, err
	}
	policy, err := validatedAuthorizationPolicyItem(item, etag, scopeID)
	return policy, etag, session, err
}

func validatedAuthorizationPolicyItem(item *storedItem, etag azcore.ETag, scopeID string) (*AuthorizationPolicy, error) {
	if item == nil {
		return nil, nil
	}
	if item.ID != authorizationPolicyItemID || item.ScopeID != scopeID || item.Kind != "authorization" || etag == "" || !validAuthorizationPolicy(item.Policy, scopeID) {
		return nil, protocolError(503, "authorization_store_unavailable")
	}
	return item.Policy, nil
}

// readAuthorizationPolicyAt preserves both independent causal minima without
// interpreting Cosmos' opaque session tokens. Only the application's policy
// revision orders authority; equal revisions must have identical policy bodies.
func (s *CosmosStore) readAuthorizationPolicyAt(ctx context.Context, scopeID, dataMinimum string) (selected *AuthorizationPolicy, etag azcore.ETag, resultErr error) {
	ctx = withAuthorizationSessions(ctx)
	defer func() {
		if resultErr == nil {
			if err := observeAuthorizationPolicy(ctx, scopeID, selected); err != nil {
				selected, etag, resultErr = nil, "", err
			}
		}
	}()
	authorization, authorizationETag, _, err := s.readAuthorizationPolicy(ctx, scopeID, "")
	if err != nil || dataMinimum == "" {
		return authorization, authorizationETag, err
	}
	// This point read intentionally bypasses the authorization token holder.
	// Its response neither replaces that holder nor the caller's data chain.
	item, dataETag, _, err := s.read(ctx, scopeID, authorizationPolicyItemID, dataMinimum)
	if err != nil {
		return nil, "", err
	}
	dataPolicy, err := validatedAuthorizationPolicyItem(item, dataETag, scopeID)
	if err != nil {
		return nil, "", err
	}
	if authorization == nil && dataPolicy == nil {
		return nil, "", nil
	}
	if authorization == nil || dataPolicy == nil || authorization.ScopeID != dataPolicy.ScopeID || authorization.Mode != dataPolicy.Mode || authorization.OwnerAccountID != dataPolicy.OwnerAccountID {
		return nil, "", protocolError(503, "authorization_store_unavailable")
	}
	if authorization.Revision == dataPolicy.Revision && !reflect.DeepEqual(authorization, dataPolicy) {
		return nil, "", protocolError(503, "authorization_store_unavailable")
	}
	if dataPolicy.Revision > authorization.Revision {
		return dataPolicy, dataETag, nil
	}
	return authorization, authorizationETag, nil
}

func (s *CosmosStore) LoadAuthorizationPolicy(ctx context.Context, scopeID string) (*AuthorizationPolicy, error) {
	policy, _, err := s.readAuthorizationPolicyAt(ctx, scopeID, "")
	return policy, err
}

func (s *CosmosStore) LoadAuthorizationPolicyAt(ctx context.Context, scopeID, dataMinimum string) (*AuthorizationPolicy, error) {
	policy, _, err := s.readAuthorizationPolicyAt(ctx, scopeID, dataMinimum)
	return policy, err
}

func (s *CosmosStore) CreateSharedScope(ctx context.Context, accountID, operationID string) (SharedScope, error) {
	ctx = withAuthorizationSessions(ctx)
	if !accountIDPattern.MatchString(accountID) || !operationIDPattern.MatchString(operationID) {
		return SharedScope{}, protocolError(400, "invalid_authorization_request")
	}
	operationID = strings.ToLower(operationID)
	account, err := s.authorizationAccount(ctx, accountID)
	if err != nil {
		return SharedScope{}, err
	}
	if account == nil {
		return SharedScope{}, protocolError(404, "account_not_found")
	}
	scopeID := sharedScopeID(accountID, operationID)
	initial := newAuthorizationPolicy(scopeID, accountID, "shared")
	var session string
	for attempt := 0; attempt < 12; attempt++ {
		if err := ctx.Err(); err != nil {
			return SharedScope{}, err
		}
		policy, _, token, err := s.readAuthorizationPolicy(ctx, scopeID, session)
		session = token
		if err != nil {
			return SharedScope{}, err
		}
		if policy != nil {
			if policy.Mode != "shared" || policy.OwnerAccountID != accountID {
				return SharedScope{}, protocolError(503, "authorization_store_unavailable")
			}
			item, _, token, err := s.readAuthorizationItem(ctx, scopeID, "a:audit:00001", session)
			session = token
			if err != nil {
				return SharedScope{}, err
			}
			if !validCreationAudit(item, scopeID, accountID, operationID) {
				return SharedScope{}, protocolError(503, "authorization_store_unavailable")
			}
			return initial.public(), nil // Creation's immutable result survives membership edits.
		}
		policyBody, _ := encodeJSON(storedItem{ID: authorizationPolicyItemID, ScopeID: scopeID, Kind: "authorization", Policy: initial})
		audit := &authorizationAudit{ActorAccountID: accountID, AccountID: accountID, OperationID: operationID, Role: "owner", Revision: 1, OccurredAt: time.Now().UTC().Format(time.RFC3339Nano)}
		auditBody, _ := encodeJSON(storedItem{ID: "a:audit:00001", ScopeID: scopeID, Kind: "authorization-audit", Audit: audit})
		batch := s.container.NewTransactionalBatch(azcosmos.NewPartitionKeyString(scopeID))
		batch.CreateItem(policyBody, nil)
		batch.CreateItem(auditBody, nil)
		var batchErr error
		session, batchErr = s.executeAuthorizationBatch(ctx, scopeID, batch, 2, session)
		if batchErr != nil {
			if authorizationContention(batchErr) {
				continue
			}
			return SharedScope{}, batchErr
		}
		return initial.public(), nil
	}
	return SharedScope{}, &ProtocolError{Status: 503, Code: "contention_retry", RetryAfter: "1"}
}

func (s *CosmosStore) ChangeMembership(ctx context.Context, scopeID, actor string, change MembershipChange) (SharedScope, error) {
	ctx = withAuthorizationSessions(ctx)
	if !accountIDPattern.MatchString(scopeID) || !accountIDPattern.MatchString(actor) || validateMembershipChange(&change) != nil {
		return SharedScope{}, protocolError(400, "invalid_authorization_request")
	}
	hash, receiptID := membershipHash(scopeID, actor, change), "a:r:"+actor+":"+change.OperationID
	var session string
	for attempt := 0; attempt < 12; attempt++ {
		if err := ctx.Err(); err != nil {
			return SharedScope{}, err
		}
		policy, etag, token, err := s.readAuthorizationPolicy(ctx, scopeID, session)
		session = token
		if err != nil {
			return SharedScope{}, err
		}
		if policy == nil || policy.Mode != "shared" || policy.OwnerAccountID != actor {
			return SharedScope{}, protocolError(403, "forbidden")
		}
		receipt, _, token, err := s.readAuthorizationItem(ctx, scopeID, receiptID, session)
		session = token
		if err != nil {
			return SharedScope{}, err
		}
		if receipt != nil {
			if receipt.AuthorizationReceipt != nil && receipt.AuthorizationReceipt.Result.Revision > policy.Revision {
				// An exact replay can see the receipt of a concurrent commit
				// after the earlier policy read. Advance using that read's token.
				policy, etag, token, err = s.readAuthorizationPolicy(ctx, scopeID, session)
				session = token
				if err != nil {
					return SharedScope{}, err
				}
				if policy == nil || policy.Mode != "shared" || policy.OwnerAccountID != actor {
					return SharedScope{}, protocolError(503, "authorization_store_unavailable")
				}
			}
			if !validAuthorizationReceipt(receipt, scopeID, actor, receiptID, policy.Revision) {
				return SharedScope{}, protocolError(503, "authorization_store_unavailable")
			}
			if receipt.AuthorizationReceipt.Hash != hash {
				return SharedScope{}, protocolError(409, "idempotency_mismatch")
			}
			result := receipt.AuthorizationReceipt.Result
			if result.Revision != change.BaseRevision+1 || !membershipResultMatches(result, change) {
				return SharedScope{}, protocolError(503, "authorization_store_unavailable")
			}
			return receipt.AuthorizationReceipt.Result, nil
		}
		account, err := s.authorizationAccount(ctx, change.AccountID)
		if err != nil {
			return SharedScope{}, err
		}
		if account == nil {
			return SharedScope{}, protocolError(404, "account_not_found")
		}
		updated, audit, err := applyMembership(policy, actor, change)
		if err != nil {
			// A concurrent exact replay can commit between the receipt read and
			// policy read. Retry stale revision once through the receipt lookup.
			if e, ok := err.(*ProtocolError); ok && e.Code == "membership_conflict" && attempt < 1 {
				continue
			}
			return SharedScope{}, err
		}
		result := updated.public()
		policyBody, _ := encodeJSON(storedItem{ID: authorizationPolicyItemID, ScopeID: scopeID, Kind: "authorization", Policy: updated})
		auditBody, _ := encodeJSON(storedItem{ID: fmt.Sprintf("a:audit:%05d", updated.Revision), ScopeID: scopeID, Kind: "authorization-audit", Audit: &audit})
		receiptBody, _ := encodeJSON(storedItem{ID: receiptID, ScopeID: scopeID, Kind: "authorization-receipt", AuthorizationReceipt: &authorizationReceipt{Hash: hash, Result: result}})
		batch := s.container.NewTransactionalBatch(azcosmos.NewPartitionKeyString(scopeID))
		batch.ReplaceItem(authorizationPolicyItemID, policyBody, &azcosmos.TransactionalBatchItemOptions{IfMatchETag: &etag})
		batch.CreateItem(auditBody, nil)
		batch.CreateItem(receiptBody, nil)
		var batchErr error
		session, batchErr = s.executeAuthorizationBatch(ctx, scopeID, batch, 3, session)
		if batchErr != nil {
			if authorizationContention(batchErr) {
				continue
			}
			return SharedScope{}, batchErr
		}
		return result, nil
	}
	return SharedScope{}, &ProtocolError{Status: 503, Code: "contention_retry", RetryAfter: "1"}
}

func validAuthorizationReceipt(item *storedItem, scopeID, actor, receiptID string, currentRevision int64) bool {
	if item == nil || item.ID != receiptID || item.ScopeID != scopeID || item.Kind != "authorization-receipt" || item.AuthorizationReceipt == nil || !accountIDPattern.MatchString(item.AuthorizationReceipt.Hash) {
		return false
	}
	result := item.AuthorizationReceipt.Result
	if result.ScopeID != scopeID || result.OwnerAccountID != actor || result.Revision < 2 || result.Revision > currentRevision || result.Members == nil {
		return false
	}
	policy := &AuthorizationPolicy{ScopeID: result.ScopeID, OwnerAccountID: result.OwnerAccountID, Mode: "shared", Revision: result.Revision, Members: make(map[string]ScopeMember, len(result.Members))}
	for _, member := range result.Members {
		if _, duplicate := policy.Members[member.AccountID]; duplicate {
			return false
		}
		policy.Members[member.AccountID] = member
	}
	return validAuthorizationPolicy(policy, scopeID)
}

func validCreationAudit(item *storedItem, scopeID, accountID, operationID string) bool {
	if item == nil || item.ID != "a:audit:00001" || item.ScopeID != scopeID || item.Kind != "authorization-audit" || item.Audit == nil {
		return false
	}
	audit := *item.Audit
	if _, err := time.Parse(time.RFC3339Nano, audit.OccurredAt); err != nil || !strings.HasSuffix(audit.OccurredAt, "Z") {
		return false
	}
	audit.OccurredAt = ""
	return audit == (authorizationAudit{ActorAccountID: accountID, AccountID: accountID, OperationID: operationID, Role: "owner", Revision: 1})
}

func membershipResultMatches(result SharedScope, change MembershipChange) bool {
	for _, member := range result.Members {
		if member.AccountID == change.AccountID {
			return member.Role == change.Role && member.PermissionVersion == strconv.FormatInt(result.Revision, 10)
		}
	}
	return false
}

func (s *CosmosStore) executeAuthorizationBatch(ctx context.Context, scopeID string, batch azcosmos.TransactionalBatch, count int, session string) (string, error) {
	session, err := authorizationSession(ctx, scopeID, session)
	if err != nil {
		return session, err
	}
	response, err := s.container.ExecuteTransactionalBatch(ctx, batch, &azcosmos.TransactionalBatchOptions{SessionToken: session, ConsistencyLevel: azcosmos.ConsistencyLevelSession.ToPtr()})
	session = nextSession(session, response.RawResponse)
	if response.SessionToken != "" {
		session = response.SessionToken
	}
	var service *azcore.ResponseError
	if errors.As(err, &service) {
		session = nextSession(session, service.RawResponse)
	}
	if rememberErr := rememberAuthorizationSession(ctx, scopeID, session); rememberErr != nil {
		return session, rememberErr
	}
	if err != nil {
		if errors.As(err, &service) && (service.StatusCode == 409 || service.StatusCode == 412) {
			return session, protocolError(service.StatusCode, "authorization_contention")
		}
		return session, cosmosError(err)
	}
	status := batchStatusForOperations(response, count)
	if status == 200 {
		return session, nil
	}
	if status == 409 || status == 412 {
		return session, protocolError(status, "authorization_contention")
	}
	if status == 429 {
		return session, &ProtocolError{Status: 429, Code: "rate_limited", RetryAfter: "1"}
	}
	return session, protocolError(503, "batch_failed")
}

func authorizationContention(err error) bool {
	e, ok := err.(*ProtocolError)
	return ok && e.Code == "authorization_contention"
}
