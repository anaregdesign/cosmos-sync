import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:cosmos_sync/cosmos_sync_browser.dart';
import 'package:web/web.dart' as web;

import 'workspace_repository_base.dart';

class WorkspaceRepository extends WorkspaceRepositoryBase {
  WorkspaceRepository({
    this.namespace = 'cosmos-sync-example-v1',
    super.transportFactory,
  }) {
    if (!RegExp(r'^[a-z0-9-]{1,64}$').hasMatch(namespace)) {
      throw ArgumentError('Use an explicit application cache namespace.');
    }
  }

  final String namespace;
  Map<String, Object?>? _verifiedIndex;
  String get _registryKey => '$namespace.cache-registry';

  @override
  Future<void> prepare() async {
    if (!web.window.isSecureContext) {
      throw UnsupportedError('Browser workspaces require a secure context.');
    }
    _registeredNames();
  }

  @override
  Future<Map<String, Object?>?> readIndex() async => _verifiedIndex;

  @override
  Future<void> saveIndex(Map<String, Object?> value) async {
    _verifiedIndex = Map<String, Object?>.unmodifiable(value);
  }

  @override
  Future<CacheStore> openCache(String identity) async {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(identity)) {
      throw ArgumentError('Invalid verified cache identity.');
    }
    final name = '$namespace:$identity';
    await _withLock('$namespace:registry', () async {
      final names = _registeredNames();
      if (!names.contains(name)) {
        if (names.length >= 64) {
          throw StateError('Sign out to clear the browser cache capacity.');
        }
        names.add(name);
        names.sort();
        web.window.localStorage.setItem(_registryKey, jsonEncode(names));
      }
    });
    return IndexedDbCache.open(name);
  }

  List<String> _registeredNames() {
    final raw = web.window.localStorage.getItem(_registryKey);
    if (raw == null) return [];
    if (raw.length > 64 * (namespace.length + 68) + 2) {
      throw StateError('Browser cache registry needs explicit repair.');
    }
    final Object? value;
    try {
      value = jsonDecode(raw);
    } on FormatException {
      throw StateError('Browser cache registry needs explicit repair.');
    }
    if (value is! List ||
        value.length > 64 ||
        value.any(
          (name) =>
              name is! String ||
              !RegExp(
                '^${RegExp.escape(namespace)}:[0-9a-f]{64}\$',
              ).hasMatch(name),
        ) ||
        value.toSet().length != value.length) {
      throw StateError('Browser cache registry needs explicit repair.');
    }
    return value.cast<String>().toList();
  }

  @override
  Future<void> purge() async {
    _verifiedIndex = null;
    await _withLock('$namespace:registry', () async {
      for (final name in _registeredNames()) {
        final cache = await IndexedDbCache.open(name);
        try {
          await cache.purgeAndPause('signed_out');
        } finally {
          await cache.close();
        }
        await _withLock('cosmos-sync:indexeddb:$name', () => _delete(name));
      }
      web.window.localStorage.removeItem(_registryKey);
    });
  }

  Future<void> _delete(String name) async {
    final completion = Completer<void>();
    final request = web.window.indexedDB.deleteDatabase(name);
    request.onsuccess = ((web.Event _) {
      if (!completion.isCompleted) completion.complete();
    }).toJS;
    void fail() {
      if (!completion.isCompleted) {
        completion.completeError(
          StateError('Browser cache deletion failed; retry sign-out.'),
        );
      }
    }

    request.onerror = ((web.Event _) => fail()).toJS;
    request.onblocked = ((web.Event _) => fail()).toJS;
    await completion.future.timeout(const Duration(seconds: 10));
  }

  Future<void> _withLock(String name, Future<void> Function() action) async {
    final completed = Completer<void>();
    final request = web.window.navigator.locks
        .request(
          name,
          web.LockOptions(mode: 'exclusive', ifAvailable: true),
          ((web.Lock? lock) {
            Future<JSAny?> perform() async {
              try {
                if (lock == null) {
                  throw StateError(
                    'A browser workspace is busy in another tab.',
                  );
                }
                await action();
                completed.complete();
              } catch (error, stack) {
                // Preserve the Dart error instead of boxing it in a JS rejection.
                completed.completeError(error, stack);
              }
              return null;
            }

            return perform().toJS;
          }).toJS,
        )
        .toDart
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {
            if (!completed.isCompleted) completed.completeError(error, stack);
            Error.throwWithStackTrace(error, stack);
          },
        );
    await Future.wait<void>([completed.future, request]);
  }
}
