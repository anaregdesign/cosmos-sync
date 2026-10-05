# Local queries

`LocalQuery` filters and sorts the durable local views for the client's authorized scope. It works offline and includes optimistic pending overlays. Synchronization fills the cache independently; this API does not expose Cosmos SQL or issue server queries.

```dart
final definition = LocalQuery(
  filters: [QueryFilter.eq(QueryField.named('status'), 'open')],
  orderBy: [QueryOrder(QueryField.named('priority'), descending: true)],
  limit: 25,
);
final first = client.query(definition);
for (final document in first.documents) {
  print('${document.id}: ${document.data}');
}

final cursor = first.nextCursor;
if (cursor != null) {
  final second = client.query(LocalQuery(
    filters: definition.filters,
    orderBy: definition.orderBy,
    limit: 25,
    startAfter: cursor,
  ));
  print(second.documents.length);
}

final subscription = client.watchQuery(definition).listen((snapshot) {
  print('cache=${snapshot.fromCache}, incomplete=${snapshot.isIncomplete}');
  print('coverage=${snapshot.completeAtCursor}');
  print('pending=${snapshot.hasPendingWrites}, conflicts=${snapshot.hasConflicts}');
});
// Later: await subscription.cancel();
```

An empty page has no next cursor. A nonempty page's next cursor is a position, not a promise of another page. It captures every ordered field value and the document ID, remains usable if the source document is deleted, and is bound to the filter/order definition plus the client's identity/scope context, including optional verified identity generation/credential metadata. A limit may change between pages. Cache or server changes can move documents across page boundaries; pagination does not freeze a snapshot. Start again when the identity, identity generation, scope or permission version changes.

## Predicate semantics

All filters are combined with AND. `QueryField(['profile', 'city'])` addresses a nested field; `QueryField.named('profile.city')` addresses one literal field containing a dot. Paths do not interpret array indexes or expressions.

| Operator | Supported values | Missing field | Explicit null field |
| --- | --- | --- | --- |
| `eq` | JSON values, with deep equality | Never matches | Matches only `eq(null)` |
| `ne` | JSON values, with deep equality | Never matches | Never matches; `ne(null)` matches no documents |
| `lt`, `lte`, `gt`, `gte` | Number or string | Never matches | Never matches |
| `arrayContains` | Any JSON value | Never matches | Never matches; an array containing null matches `arrayContains(null)` |

Numeric equality treats `1` and `1.0` as equal. Strings and numbers are never coerced. Ranges compare numbers with numbers or strings with strings; mixed types do not match. Arrays compare elements in order and maps compare their key/value contents regardless of insertion order. Only JSON values are supported; NaN, infinity, DateTime and other application objects are rejected. Store application-specific dates in a consistent JSON representation.

Queries use Dart's decoded `num` values. Browsers cannot preserve every integer beyond JavaScript's exact integer range (±9,007,199,254,740,991). Represent exact larger integers or decimal amounts as strings with an application-defined comparison strategy; this query API does not supply arbitrary-precision decimal comparisons.

An ordered field must exist, while an existing null is ordered first in ascending order. The total ascending sort order is null, boolean (`false`, `true`), number, string, array, map. Strings and map keys compare Unicode scalar values without locale collation or normalization. Arrays compare lexicographically; maps compare sorted key/value pairs lexicographically. Descending reverses the requested field comparison. Ascending document ID is always the final tie-breaker, including after descending fields. Queries without sort fields use ascending document ID. Deleted views never appear.

## Coverage, writes and watches

Every query snapshot has `fromCache == true`. `isIncomplete` stays true until the initial authorized-scope replay finishes and saves a cursor. `completeAtCursor` then names the cursor through which the **confirmed base** has been covered. Pending local changes overlay that base, so this is not a claim that the query result equals the server result. Offline results may be stale, and an offline device cannot discover a permission revocation immediately. Resync, cache purge or paused authorization clears the coverage claim.

`hasPendingWrites` and `hasConflicts` are conservative scope-wide flags. They include pending deletions and edits that moved documents out of this query. Individual result documents retain their own pending/conflict flags. Watches emit an initial local snapshot, then committed cache changes and coverage-only changes. A watcher does not itself start networking: enable the sync/change-notification mechanism or call `sync()` to refresh server changes.

## Bounds and differences from Firestore

The AST accepts at most 16 filters, 8 distinct ordered fields and field paths of 16 segments (128 UTF-8 bytes per segment). A specified limit must be 1..1000; omitting it returns all matching cached views. Each predicate/cursor value is limited to 8 KiB, 16 nested levels and 256 entries per array/map. The versioned `toJson()`/`LocalQuery.fromJson()` codec rejects unsupported operators and unknown fields. It is for local persistence, not a server query protocol.

Evaluation scans the entire cached scope and then sorts matches: O(N × filters + N log N × sort fields), with O(N) intermediate memory. A small result limit does not avoid that scan. Use a dedicated isolate for large native caches, measure on target devices, and avoid a scope size that exceeds the application's local storage/memory budget. No automatic query indexes are provided.

Firestore also runs offline queries against cached documents and documents that cache results may be incomplete. Cosmos Sync uses explicit scope-replay coverage rather than a server query listener's freshness metadata. [Firestore offline documentation](https://firebase.google.com/docs/firestore/manage-data/enable-offline)

The missing-field ordering and not-equal null behavior follow Firestore's documented rules. This does not imply general query compatibility. [Firestore ordering](https://firebase.google.com/docs/firestore/query-data/order-limit-data), [Firestore query operators](https://firebase.google.com/docs/firestore/query-data/queries)

Cosmos Sync deliberately supplies a narrower JSON API. It does not support OR/IN, aggregations, collection groups, server indexes, arbitrary SQL/functions, Firestore typed values, Firestore's index constraints, or an identical implicit document-ID sort direction. Range filtering and mixed-type sorting follow the rules above. Its snapshot cursor includes every sort value and ID to make ties deterministic; Firestore also documents the importance of extra cursor fields when values repeat. [Firestore cursors](https://firebase.google.com/docs/firestore/query-data/query-cursors)
