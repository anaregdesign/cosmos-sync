# cosmos_sync

Dart/Flutter offline documents through an OIDC BFF for Cosmos DB for NoSQL.
**Unpublished v0.2 preview; public licensing remains undecided.** Native SQLite and
Chromium IndexedDB preserve confirmed data, pending overlays and exact durable
operations. The BFF alone holds Cosmos credentials. This is a finite document API,
with [Firestore differences](../../docs/query.md).

## Durable local writes

```dart
final client = await CosmosSyncClient.open(
  path: cacheIdentity, // app-private native path; origin-local database on web
  transport: HttpSyncTransport(
    baseUri: Uri.parse('https://your-bff.example'),
    tokenProvider: () => auth.currentAccessToken(),
    scopeMode: SyncScopeMode.user, // optional authorized tenant scope
  ),
);
await client.sync();
final watch = client.watch('note').listen((view) {
  print('${view?.data}; pending=${view?.hasPendingWrites}');
});
await client.put('note', {'text': 'Available offline', 'rank': 1});
final acknowledged = client.waitForPendingWrites();
await client.flush();
await acknowledged; // captures writes present when called; later edits excluded
client.startWatching(); // hints plus polling fallback while app is running
await watch.cancel();
await client.signOut();
await client.close();
```

Await put/delete/retryConflict/discard: success means the storage transaction
committed, not that the server accepted it. Loaded get/list/query reads are
synchronous. A new cache needs a server session; a verified cache can reopen
fully offline. IDs and data are bounded JSON, with exact safe integers. put
replaces the whole document; delete retains a tombstone, excluded from list/query.

## Queries and coverage

```dart
final query = LocalQuery(limit: 20);
final result = client.query(query);
print(result.documents);
final subscription = client.watchQuery(query).listen((page) {
  print(page.metadata.completeAtCursor);
});
```

Queries scan local views, including pending overlays, with a finite immutable AST,
AND filters, explicit field segments, deterministic JSON order and ID tie-breaker.
Query cursors bind scope and definition, and differ from server sync cursors.
[Complete semantics](../../docs/query.md) cover null/missing/type boundaries,
pagination under edits and unsupported operators. Local filtering does not reduce
full-scope network/RU costs. Completed bootstrap establishes coverage through a
committed cursor; offline results still cannot promise current freshness/access.

## Conflicts, retry and bootstrap

The first edit preserves the version observed at enqueue; pulls never rebase it.
Later same-document edits depend on a predecessor's actual ACK. Pending requests
are durably locked before send, and retry/restart reuse the exact operation ID,
base and data. Late ACKs preserve newer overlays. Lost responses replay immutable
server receipts rather than create a second write.

A conflict remains in `pending`, blocks successors for that document, and permits
explicit awaited `retryConflict(operationId, data: mergedData)` or `discard`.
A queued attempted mutation with unknown outcome cannot be discarded safely.
ACK waits fail on conflict/discard/revocation/close. Network/429/5xx failures retain
operations with persisted backoff/Retry-After; observe `statuses` and flush results.

Bootstrap uses a bounded fixed-cutover snapshot where enabled and otherwise
retained-journal replay. Snapshot progress/page/data cursor commits are atomic;
interrupted coverage stays incomplete. 410 generation recovery clears confirmed
coverage while preserving exact outbox identities and observed bases. Receipts,
tombstones and journal are retained without TTL; server capacity exhaustion needs
operator action. Hints never advance the durable data cursor; polling recovers
missed events. No background-execution guarantee is implied.

## Identity, cache ownership and limits

Sessions bind principal, scope, mode and permission version. Fresh-token requests
assert that same identity; the server derives routing. 401/403 or a changed session
conservatively purges cache/outbox and pauses. `resume()` explicitly adopts a newly
verified session. `await signOut()` drains in-flight work before purge. Offline
revocation cannot be learned before reconnection, and purge may discard local edits.

Use one isolate/cache owner per principal/scope. Native SQLite guards duplicate
opens within an isolate and uses advisory file locks across processes; separate
isolates in one process must coordinate ownership at the application level.
Browser persistence requires IndexedDB and Web Locks, with strict transaction
commit and typed capability/busy failures. Do not substitute an in-memory fallback.
Browser storage remains subject to eviction/user deletion; other browsers are
unverified until measured. Native SQLite is plaintext; logical purge cannot erase
backups/WAL/snapshots forensically. Larger native caches should use a dedicated
isolate; queries scan and sort rather than use a server planner.

[Platform evidence](../../docs/platforms.md), [performance](../../docs/performance.md),
[wire protocol](../../docs/protocol.md) and [security](../../docs/security.md) describe
actual support. No Firestore compatibility, global order/cross-partition transaction,
automatic merge, external Cosmos writer ingestion or cloud RU/SLA is promised.

## Development and release preparation

```sh
dart pub get
dart analyze --fatal-infos
dart test
dart test --platform chrome
dart run example/cosmos_sync_example.dart
dart pub publish --dry-run
```

The runnable native example uses a demo transport and a real reopened SQLite file.
The monorepo separately tests authenticated Go HTTP and the official Cosmos emulator.
Stable Flutter compatibility uses SQLite 3.5.x without dependency overrides;
newer SQLite package hooks currently conflict with stable Flutter's pinned meta.
The browser reload probe in `web/cache_reload_probe.dart` verifies exact outbox
identities, observed bases, overlays, scope, cursor and consistency envelope after
a full page reload. Publication
needs owner-approved license/source/publisher/version and registry access; no command
here publishes or creates Azure resources. See [release gates](../../docs/release.md).
