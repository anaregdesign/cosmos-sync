# cosmos_sync

Native Dart and Flutter offline document synchronization through the Cosmos Sync
BFF for Azure Cosmos DB for NoSQL. **Unpublished development preview.** No public
license has been selected; the `LICENSE` file records that decision as pending.

The SDK stores documents and writes locally in SQLite and sends authenticated
requests to the BFF. It never receives Cosmos keys or privileged resource tokens.
This package provides a small document API, not Firestore API compatibility.

## Use

```dart
import 'package:cosmos_sync/cosmos_sync.dart';

final transport = HttpSyncTransport(
  baseUri: Uri.parse('https://your-bff.example'),
  // Integrate your OIDC provider here; return a current access token each time.
  tokenProvider: () => auth.currentAccessToken(),
);
final client = await CosmosSyncClient.open(
  path: '$appPrivateDirectory/cosmos-sync.sqlite',
  transport: transport,
);
await client.sync(); // Initial retained-journal replay; durable resume afterward.

final subscription = client.watch('note-1').listen((snapshot) {
  print('${snapshot?.data}, pending=${snapshot?.hasPendingWrites}');
});
client.put('note-1', {'text': 'Available immediately, even offline'});
final result = await client.flush();
// Network/429/5xx failures keep the write and a persistent retry deadline.
print('Remaining: ${result.remaining}; retry at ${result.retryAt}');
client.startPolling(); // Optional; pull then flush due writes every 15 seconds.

await subscription.cancel();
await client.close();
```

`open` reuses the stored verified scope when reopening an existing cache offline.
A new cache fetches `/v1/session`; optionally pass an earlier **server-verified**
`SessionInfo` to initialize it offline. Do not derive that scope from unvalidated
JWT claims. `flush` completes initial bootstrap before sending; very large
journals may require additional `sync` calls beyond its 100-page budget.

`get` and `list` are local synchronous reads. `put` fully replaces document data;
there are no field transforms, patch operations or local query indexes. `delete`
creates a tombstone (`snapshot.deleted == true`), omitted from `list()` unless
`includeDeleted: true`. IDs contain 1–128 ASCII letters, numbers, dot, underscore
or hyphen and start with a letter/number. Local JSON data is limited to 255 KiB,
staying below the BFF's 256 KiB data and 512 KiB request-body limits.

## Durable writes and conflicts

- Confirmed server data and pending local overlays are stored separately. A
  delayed ACK never replaces a newer local edit or a newer confirmed version.
- Each first edit records the server version observed **when editing**. Later
  pulls cannot silently rebase it. Following edits to the same document depend
  on the actual predecessor ACK version. Unseen documents use version 0 and
  conservatively conflict if they already exist remotely.
- Immediately before first transmission, the exact request/baseVersion is
  durably locked. Retry and process restart reuse the same operation ID, data
  and baseVersion. The BFF atomically stores document, journal and replay receipt.
- `client.pending` exposes queued, conflict and rejected writes. A 409 conflict
  blocks later edits to that document while other documents can proceed.
  Resolve intentionally with `retryConflict(operationId, data: mergedData)`;
  this creates a new operation ID and adopts the current confirmed base. Omit
  `data` to retry the same put, or to retry a delete.
- `discard(operationId)` removes an unattempted, conflicted or rejected edit.
  A queued attempted operation with an unknown result cannot be discarded: it
  may already have committed. Replay it to learn its outcome. Discarding a
  predecessor preserves a later edit's original base, so that edit may conflict
  again rather than silently overwrite remote data.
- Retry deadlines for writes are persisted; exponential backoff and
  `Retry-After` apply. Automated polling also honors pull/preflight throttling.
  Explicit manual calls remain caller-triggered. Observe `statuses` for errors.

Each sync page and its opaque resume cursor commit in one SQLite transaction.
410 `resync_required` clears the confirmed cache/cursor and replays the retained
journal; pending requests keep their identities and locked payloads. The opaque
BFF consistency envelope is persisted with ACKs/pages and forwarded for
cross-replica read-your-writes. It is consistency metadata, not a Cosmos auth key.

## Authorization and storage boundary

Before network sync/flush, the SDK verifies scope and permission version with
`/session`. Mutation/sync requests carry the expected verified scope so the BFF
can reject a token identity switch between verification and transmission.
401/403 or a scope/permission change conservatively **purges cache and outbox**
and pauses synchronization. After signing in, explicitly call `resume()` to
adopt the current verified scope, then `sync()`. Offline revocation cannot be
detected until reconnection. Pending edits are intentionally lost on revocation.
On app logout, `await client.signOut()` stops new work and waits for any in-flight
request before purging and pausing. Then `await client.close()`. Avoid directly
purging storage while synchronization is in flight.

Choose an app-private directory. SQLite is unencrypted in this adapter. Purge
means logical database deletion, not guaranteed forensic removal from storage,
WAL files, OS snapshots or backups. Do not share a cache path across clients,
processes, isolates or identities. The adapter guards aliases within one isolate
and uses an OS advisory lock; POSIX locks are process-scoped, so one isolate must
own the file. Platform/app lifecycle coordination remains the app's duty.

The initial adapter uses synchronous native `sqlite3`; Flutter mobile/desktop and
Dart VM are the intended targets. Run larger caches in a dedicated isolate to
avoid UI blocking. **Web is not supported by this adapter**, and this slice has
not been device-tested on every native platform. The current sqlite3 package
bundles native SQLite through Dart build hooks, requiring Dart 3.12 or newer.

Ordering and transactions are scoped to one BFF-authorized logical partition.
There are no cross-partition transactions, global ordering, arbitrary SQL
queries, Firestore listeners, browser persistence or production RU guarantees.
Polling delivers change hints; it is not realtime fanout. The v0 server retains
journal entries, receipts and deletion tombstones without TTL, trading growing
storage/RU cost for offline replay safety. Live Azure integration/load tests,
compaction, encryption and a browser cache adapter remain future work.

## Develop and publish preparation

```sh
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze
dart test
dart run example/cosmos_sync_example.dart
dart pub publish --dry-run
```

The executable example uses an in-memory **demo BFF**, while the cache is a real
temporary SQLite file and is reopened to demonstrate offline durability. The
monorepo also provides a cross-stack smoke test against the authenticated Go BFF.
See the repository protocol and security documentation before server deployment.

Release still needs a public-license decision, owner-approved publication and
pub.dev publisher/account setup. A dry run does not reserve the package name.
No real publication or Azure resources are created by these commands.

References: [Dart publishing](https://dart.dev/tools/pub/publishing),
[sqlite3 native assets](https://pub.dev/packages/sqlite3),
[HTTP package](https://pub.dev/packages/http).
