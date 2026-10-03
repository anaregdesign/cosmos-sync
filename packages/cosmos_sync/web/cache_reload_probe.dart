import 'dart:convert';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:cosmos_sync/src/indexed_db_cache.dart';
import 'package:web/web.dart' as web;

/// Standalone local browser reload probe, not an application authentication flow.
Future<void> main() async {
  final name = Uri.base.queryParameters['db'] ?? 'cosmos-sync-reload-probe';
  try {
    final cache = await IndexedDbCache.open(name);
    final firstLoad = cache.session == null;
    if (firstLoad) {
      await cache.initialize(
        const SessionInfo(
          scopeId: 'probe-scope',
          principalId: 'probe-principal',
          permissionVersion: '1',
        ),
      );
      await cache.enqueue(
        operationId: 'c2d7275b-4fe7-4b95-8d16-81b09eb3366a',
        documentId: 'pending',
        kind: MutationKind.put,
        data: {'text': 'saved before reload'},
      );
      await cache.prepare(cache.pending.single);
      await cache.enqueue(
        operationId: '12fa7de0-0801-46d9-848d-344772d639be',
        documentId: 'pending',
        kind: MutationKind.put,
        data: {'text': 'later overlay'},
      );
      await cache.applyPage(
        SyncPage(
          changes: [
            ServerDocument(
              id: 'confirmed',
              data: {'text': 'remote cache'},
              version: 7,
              deleted: false,
            ),
          ],
          cursor: 'durable-resume-cursor',
          hasMore: false,
        ),
        'opaque-consistency-envelope',
      );
    }
    final state = <String, Object?>{
      'stage': firstLoad ? 'CREATED' : 'RESTORED_AFTER_RELOAD',
      'database': name,
      'scope': cache.session!.toJson(),
      'outbox': cache.pending
          .map(
            (mutation) => {
              'operationId': mutation.operationId,
              'baseVersion': mutation.baseVersion,
              'observedVersion': mutation.observedVersion,
              'predecessorOperationId': mutation.predecessorOperationId,
            },
          )
          .toList(),
      'overlay': cache.get('pending')!.data,
      'confirmedVersion': cache.get('confirmed')!.version,
      'cursor': cache.cursor,
      'consistencyToken': cache.consistencyToken,
    };
    await cache.close();
    web.document.body!.textContent = const JsonEncoder.withIndent(
      '  ',
    ).convert(state);
    web.document.title = state['stage']! as String;
  } catch (error) {
    web.document.body!.textContent = 'PROBE_FAILED: $error';
    web.document.title = 'PROBE_FAILED';
  }
}
