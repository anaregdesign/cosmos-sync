package syncbff

import (
	"context"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/data/azcosmos"
)

const identityDirectoryItemID = "a:identity-directory-v1"

var identityDirectoryPartition = namespacedID("identity-directory-partition-v1")

type cosmosIdentityDirectoryStore struct{ cosmos *CosmosStore }

func (s cosmosIdentityDirectoryStore) loadIdentityDirectory(ctx context.Context) (*identityDirectoryState, string, error) {
	item, etag, _, err := s.cosmos.readAuthorizationItem(ctx, identityDirectoryPartition, identityDirectoryItemID, "")
	if err != nil || item == nil {
		return nil, "", err
	}
	if item.ID != identityDirectoryItemID || item.ScopeID != identityDirectoryPartition || item.Kind != "identity-directory-v1" ||
		item.IdentityDirectory == nil || etag == "" || !validIdentityDirectory(item.IdentityDirectory) {
		return nil, "", protocolError(503, "identity_directory_unavailable")
	}
	return item.IdentityDirectory, string(etag), nil
}

func (s cosmosIdentityDirectoryStore) compareIdentityDirectory(ctx context.Context, version string, state *identityDirectoryState) error {
	if !validIdentityDirectory(state) {
		return protocolError(503, "identity_directory_unavailable")
	}
	body, err := encodeJSON(storedItem{ID: identityDirectoryItemID, ScopeID: identityDirectoryPartition,
		Kind: "identity-directory-v1", IdentityDirectory: state})
	if err != nil {
		return protocolError(503, "identity_directory_unavailable")
	}
	batch := s.cosmos.container.NewTransactionalBatch(azcosmos.NewPartitionKeyString(identityDirectoryPartition))
	if version == "" {
		batch.CreateItem(body, nil)
	} else {
		etag := azcore.ETag(version)
		batch.ReplaceItem(identityDirectoryItemID, body, &azcosmos.TransactionalBatchItemOptions{IfMatchETag: &etag})
	}
	_, err = s.cosmos.executeAuthorizationBatch(ctx, identityDirectoryPartition, batch, 1, "")
	return err
}
