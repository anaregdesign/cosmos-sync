import 'package:cosmos_sync_example/auth/native_oidc.dart';
import 'package:cosmos_sync_example/auth/oidc.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const key = 'cosmos_sync_example.test.unit';
  late Map<String, String> record;
  late List<MethodCall> calls;
  late NativeRefreshTokenStore store;
  bool ignoreWrite = false;
  bool ignoreDelete = false;
  bool failRead = false;
  setUp(() {
    record = {};
    calls = [];
    ignoreWrite = false;
    ignoreDelete = false;
    failRead = false;
    store = NativeRefreshTokenStore(key: key);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          final arguments = call.arguments as Map;
          final name = arguments['key'] as String;
          switch (call.method) {
            case 'read':
              if (failRead) {
                throw PlatformException(
                  code: 'native_error',
                  message: 'raw-refresh-secret',
                );
              }
              return record[name];
            case 'write':
              if (!ignoreWrite) {
                record[name] = arguments['value'] as String;
              }
              return null;
            case 'delete':
              if (!ignoreDelete) {
                record.remove(name);
              }
              return null;
            default:
              throw StateError('unexpected mocked storage operation');
          }
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  Matcher storageFailure = isA<AuthException>()
      .having((error) => error.code, 'code', 'storage_failed')
      .having(
        (error) => error.toString(),
        'message',
        isNot(contains('secret')),
      );

  test(
    'write and delete are read back and touch only the isolated key',
    () async {
      await store.write('refresh-secret');
      expect(calls.map((call) => call.method), ['write', 'read']);
      expect(record[key], 'refresh-secret');
      await store.clear();
      expect(calls.map((call) => call.method), [
        'write',
        'read',
        'delete',
        'read',
      ]);
      expect(record, isEmpty);
      expect(
        calls.every((call) => (call.arguments as Map)['key'] == key),
        true,
      );
    },
  );

  test('silent platform write failure fails closed', () async {
    ignoreWrite = true;
    await expectLater(store.write('refresh-secret'), throwsA(storageFailure));
    expect(record, isEmpty);
  });

  test('silent platform deletion failure is reported', () async {
    await store.write('refresh-secret');
    ignoreDelete = true;
    await expectLater(store.clear(), throwsA(storageFailure));
    expect(record[key], 'refresh-secret');
  });

  test('native exception payloads never escape secure-store adapter', () async {
    failRead = true;
    await expectLater(store.read(), throwsA(storageFailure));
    await expectLater(store.write('refresh-secret'), throwsA(storageFailure));
    await expectLater(store.clear(), throwsA(storageFailure));
  });

  test(
    'macOS sample selects local legacy Keychain and disables synchronization',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await store.read();
      final options = (calls.single.arguments as Map)['options'] as Map;
      expect(options['usesDataProtectionKeychain'], 'false');
      expect(options['synchronizable'], 'false');
      expect(options['accountName'], 'cosmos_sync_example.auth');
    },
  );
}
