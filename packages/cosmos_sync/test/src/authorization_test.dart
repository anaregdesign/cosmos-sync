import 'dart:convert';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

final _accountId = 'a' * 64;
final _scopeId = 'b' * 64;
final _personalId = 'c' * 64;
final _memberId = 'd' * 64;
const _operationId = '119acde0-d037-4979-8e2e-2e68ba11531d';

Map<String, Object?> _policy({
  String? scopeId,
  String? ownerAccountId,
  int revision = 1,
  List<Object?> members = const [],
}) => {
  'scopeId': scopeId ?? _scopeId,
  'ownerAccountId': ownerAccountId ?? _accountId,
  'revision': revision,
  'members': members,
};

Map<String, Object?> _session({
  String? scopeId,
  String? principalId,
  String mode = 'shared',
  String permissionVersion = '1',
}) => {
  'scopeId': scopeId ?? _scopeId,
  'principalId': principalId ?? _accountId,
  'scopeMode': mode,
  'permissionVersion': permissionVersion,
};

http.Response _json(Object? value, {int status = 200}) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

HttpSyncTransport _transport(
  Future<http.Response> Function(http.Request) handler, {
  SyncScopeMode mode = SyncScopeMode.user,
  String? sharedScopeId,
  Future<String> Function()? tokenProvider,
}) => HttpSyncTransport(
  baseUri: Uri.parse('https://bff.example.test/api'),
  tokenProvider: tokenProvider ?? () async => 'api-access-token',
  client: MockClient(handler),
  scopeMode: mode,
  sharedScopeId: sharedScopeId,
);

void main() {
  group('shared data session', () {
    test('requires an exact BFF-issued ID only in shared mode', () {
      for (final id in [null, '', 'b' * 63, 'B' * 64, '../members', 'b%2F']) {
        expect(
          () => _transport(
            (_) async => _json({}),
            mode: SyncScopeMode.shared,
            sharedScopeId: id,
          ),
          throwsArgumentError,
        );
      }
      for (final mode in [SyncScopeMode.user, SyncScopeMode.tenant]) {
        expect(
          () => _transport(
            (_) async => _json({}),
            mode: mode,
            sharedScopeId: _scopeId,
          ),
          throwsArgumentError,
        );
      }
    });

    test(
      'binds selected shared scope, principal and per-member generation',
      () async {
        var tokens = 0;
        final transport = _transport(
          (request) async {
            expect(request.headers['Authorization'], 'Bearer token-$tokens');
            if (request.url.path.endsWith('/session')) {
              expect(request.url.queryParameters, {
                'scope': 'shared',
                'scopeId': _scopeId,
              });
              return _json(_session(permissionVersion: '7'));
            }
            expect(request.headers['X-Cosmos-Sync-Scope'], _scopeId);
            expect(request.headers['X-Cosmos-Sync-Principal'], _accountId);
            expect(request.headers['X-Cosmos-Sync-Scope-Mode'], 'shared');
            expect(request.headers['X-Cosmos-Sync-Permission'], '7');
            return _json({
              'changes': <Object?>[],
              'cursor': 'opaque',
              'hasMore': false,
            });
          },
          mode: SyncScopeMode.shared,
          sharedScopeId: _scopeId,
          tokenProvider: () async => 'token-${++tokens}',
        );
        addTearDown(transport.close);
        final session = await transport.sessionInfo();
        expect(session.scopeMode, SyncScopeMode.shared);
        await transport.sync();
        expect(tokens, 2);
      },
    );

    test('rejects substituted shared ID or returned legacy mode', () async {
      for (final response in [
        _session(scopeId: _personalId),
        _session(mode: 'tenant'),
        _session(mode: 'user'),
      ]) {
        final transport = _transport(
          (_) async => _json(response),
          mode: SyncScopeMode.shared,
          sharedScopeId: _scopeId,
        );
        addTearDown(transport.close);
        await expectLater(
          transport.sessionInfo(),
          throwsA(
            isA<TransportException>().having(
              (e) => e.code,
              'code',
              'invalid_session',
            ),
          ),
        );
        await expectLater(transport.sync(), throwsStateError);
      }
    });

    test(
      'rejects malformed shared principal and permission generation',
      () async {
        for (final response in [
          _session(principalId: 'A' * 64),
          _session(principalId: 'a' * 63),
          _session(principalId: 'not-a-builtin-account'),
          _session(permissionVersion: '0'),
          _session(permissionVersion: '01'),
          _session(permissionVersion: '10001'),
          _session(permissionVersion: 'opaque-legacy-version'),
        ]) {
          final transport = _transport(
            (_) async => _json(response),
            mode: SyncScopeMode.shared,
            sharedScopeId: _scopeId,
          );
          addTearDown(transport.close);
          await expectLater(
            transport.sessionInfo(),
            throwsA(
              isA<TransportException>().having(
                (e) => e.code,
                'code',
                'invalid_session',
              ),
            ),
          );
          await expectLater(transport.sync(), throwsStateError);
        }
      },
    );

    test('clears consistency envelope on changed member generation', () async {
      var revision = '2';
      final transport = _transport(
        (_) async => _json(_session(permissionVersion: revision)),
        mode: SyncScopeMode.shared,
        sharedScopeId: _scopeId,
      );
      addTearDown(transport.close);
      await transport.sessionInfo();
      transport.consistencyToken = 'old-member-session';
      await transport.sessionInfo();
      expect(transport.consistencyToken, 'old-member-session');
      revision = '4'; // Revocation/regrant must use a new generation.
      await transport.sessionInfo();
      expect(transport.consistencyToken, isNull);
    });
  });

  group('online built-in authorization management', () {
    test(
      'registration establishes identity without data scope or cursor headers',
      () async {
        var tokens = 0;
        final transport = _transport((request) async {
          expect(request.headers['Authorization'], 'Bearer token-$tokens');
          expect(request.headers.containsKey('X-Cosmos-Sync-Scope'), isFalse);
          expect(
            request.headers.containsKey('X-Cosmos-Sync-Permission'),
            isFalse,
          );
          expect(request.headers.containsKey('X-Cosmos-Sync-Session'), isFalse);
          if (request.url.path.endsWith('/account')) {
            expect(
              request.headers.containsKey('X-Cosmos-Sync-Principal'),
              isFalse,
            );
            return _json({
              'accountId': _accountId,
              'personalScopeId': _personalId,
            });
          }
          expect(request.headers['X-Cosmos-Sync-Principal'], _accountId);
          expect(request.url.path, '/api/v1/scopes');
          expect(request.method, 'POST');
          expect(jsonDecode(request.body), {'operationId': _operationId});
          return _json(_policy());
        }, tokenProvider: () async => 'token-${++tokens}');
        addTearDown(transport.close);
        transport.consistencyToken = 'data-envelope';
        final account = await transport.account();
        final policy = await transport.createSharedScope(
          CreateSharedScopeRequest(operationId: _operationId),
        );
        expect(account.personalScopeId, _personalId);
        expect(policy.ownerAccountId, account.accountId);
        expect(tokens, 2);
        expect(transport.consistencyToken, 'data-envelope');
      },
    );

    test('management after a data session asserts principal only', () async {
      final transport = _transport((request) async {
        if (request.url.path.endsWith('/session')) {
          return _json(_session(scopeId: _personalId, mode: 'user'));
        }
        expect(request.headers['X-Cosmos-Sync-Principal'], _accountId);
        expect(request.headers.containsKey('X-Cosmos-Sync-Scope'), isFalse);
        expect(
          request.headers.containsKey('X-Cosmos-Sync-Scope-Mode'),
          isFalse,
        );
        return _json(_policy());
      });
      addTearDown(transport.close);
      await transport.sessionInfo();
      await transport.sharedScopeMembers(_scopeId);
    });

    test('rejects an account/owner identity substitution', () async {
      var response = <String, Object?>{
        'accountId': _accountId,
        'personalScopeId': _personalId,
      };
      final transport = _transport((_) async => _json(response));
      addTearDown(transport.close);
      await transport.account();
      response = {'accountId': _memberId, 'personalScopeId': _personalId};
      await expectLater(
        transport.account(),
        throwsA(isA<TransportException>()),
      );
      response = _policy(ownerAccountId: _memberId);
      await expectLater(
        transport.createSharedScope(
          CreateSharedScopeRequest(operationId: _operationId),
        ),
        throwsA(
          isA<TransportException>().having(
            (e) => e.code,
            'code',
            'invalid_response',
          ),
        ),
      );
    });

    test('rejects a policy returned for a different path scope', () async {
      final transport = _transport(
        (_) async => _json(_policy(scopeId: _personalId)),
      );
      addTearDown(transport.close);
      await expectLater(
        transport.sharedScopeMembers(_scopeId),
        throwsA(isA<TransportException>()),
      );
      await expectLater(
        transport.setSharedScopeMember(
          _scopeId,
          SetSharedScopeMemberRequest(
            operationId: _operationId,
            accountId: _memberId,
            role: SharedScopeRole.reader,
            baseRevision: 1,
          ),
        ),
        throwsA(isA<TransportException>()),
      );
    });

    test(
      'retries preserve the exact management operation while refreshing token',
      () async {
        final bodies = <String>[];
        var tokens = 0;
        final transport = _transport((request) async {
          expect(request.url.path, '/api/v1/scopes/$_scopeId/members');
          expect(request.method, 'POST');
          expect(request.headers['Authorization'], 'Bearer token-$tokens');
          bodies.add(request.body);
          if (bodies.length == 1) throw http.ClientException('lost response');
          return _json(
            _policy(
              revision: 2,
              members: [
                {
                  'accountId': _memberId,
                  'role': 'reader',
                  'permissionVersion': '2',
                },
              ],
            ),
          );
        }, tokenProvider: () async => 'token-${++tokens}');
        addTearDown(transport.close);
        final request = SetSharedScopeMemberRequest(
          operationId: _operationId,
          accountId: _memberId,
          role: SharedScopeRole.reader,
          baseRevision: 1,
        );
        await expectLater(
          transport.setSharedScopeMember(_scopeId, request),
          throwsA(isA<TransportException>()),
        );
        final policy = await transport.setSharedScopeMember(
          _scopeId,
          SetSharedScopeMemberRequest.fromJson(request.toJson()),
        );
        expect(bodies[0], bodies[1]);
        expect(policy.members.single.role, SharedScopeRole.reader);
        expect(tokens, 2);
      },
    );

    test(
      'classifies stale membership separately without implicit retry',
      () async {
        var calls = 0;
        final transport = _transport((_) async {
          calls++;
          return _json({'code': 'membership_conflict'}, status: 409);
        });
        addTearDown(transport.close);
        await expectLater(
          transport.setSharedScopeMember(
            _scopeId,
            SetSharedScopeMemberRequest.create(
              accountId: _memberId,
              role: SharedScopeRole.none,
              baseRevision: 1,
            ),
          ),
          throwsA(
            isA<TransportException>()
                .having(
                  (e) => e.membershipConflict,
                  'membership conflict',
                  true,
                )
                .having((e) => e.retryable, 'retryable', false),
          ),
        );
        expect(calls, 1);
      },
    );

    test(
      'keeps recorded replay responses even when policy has advanced',
      () async {
        var calls = 0;
        final transport = _transport(
          (_) async => _json(_policy(revision: ++calls == 1 ? 5 : 2)),
        );
        addTearDown(transport.close);
        expect((await transport.sharedScopeMembers(_scopeId)).revision, 5);
        final replay = await transport.setSharedScopeMember(
          _scopeId,
          SetSharedScopeMemberRequest(
            operationId: _operationId,
            accountId: _memberId,
            role: SharedScopeRole.none,
            baseRevision: 1,
          ),
        );
        expect(replay.revision, 2);
      },
    );

    test('rejects malformed identifier before any token or request', () async {
      var calls = 0;
      final transport = _transport((_) async {
        calls++;
        return _json({});
      });
      addTearDown(transport.close);
      for (final id in [
        '../account',
        'f' * 63,
        'F' * 64,
        'f' * 64 + '/members',
      ]) {
        await expectLater(
          transport.sharedScopeMembers(id),
          throwsArgumentError,
        );
      }
      expect(calls, 0);
    });

    for (final status in [401, 403, 404, 507]) {
      test('management preserves HTTP$status classification', () async {
        final transport = _transport(
          (_) async => _json({'code': 'server_error'}, status: status),
        );
        addTearDown(transport.close);
        await expectLater(
          transport.sharedScopeMembers(_scopeId),
          throwsA(
            isA<TransportException>()
                .having((e) => e.statusCode, 'status', status)
                .having(
                  (e) => e.authorizationFailure,
                  'authorization',
                  status == 401 || status == 403,
                ),
          ),
        );
      });
    }
  });

  group('immutable authorization wire models', () {
    test('generated requests hold one version4 UUID and roundtrip exactly', () {
      final create = CreateSharedScopeRequest.create();
      final edit = SetSharedScopeMemberRequest.create(
        accountId: _memberId,
        role: SharedScopeRole.writer,
        baseRevision: 9,
      );
      for (final id in [create.operationId, edit.operationId]) {
        expect(
          id,
          matches(
            RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
            ),
          ),
        );
      }
      expect(
        CreateSharedScopeRequest.fromJson(create.toJson()).toJson(),
        create.toJson(),
      );
      expect(
        SetSharedScopeMemberRequest.fromJson(edit.toJson()).toJson(),
        edit.toJson(),
      );
    });

    test(
      'rejects missing, unsafe, owner, duplicate and invalid generation models',
      () {
        final member = {
          'accountId': _memberId,
          'role': 'reader',
          'permissionVersion': '2',
        };
        final valid = _policy(revision: 2, members: [member]);
        expect(
          SharedScope.fromJson(valid).members.single.role,
          SharedScopeRole.reader,
        );
        for (final value in [
          {...valid, 'revision': 0},
          {...valid, 'revision': 10001},
          _policy(revision: 2, members: [member, member]),
          _policy(
            revision: 2,
            members: [
              {...member, 'accountId': _accountId},
            ],
          ),
          _policy(
            revision: 2,
            members: [
              {...member, 'role': 'owner'},
            ],
          ),
          _policy(
            revision: 2,
            members: [
              {...member, 'permissionVersion': '3'},
            ],
          ),
          _policy(
            revision: 2,
            members: [
              {...member, 'permissionVersion': '01'},
            ],
          ),
          _policy(
            revision: 2,
            members: [
              {...member, 'permissionVersion': '0'},
            ],
          ),
          _policy(
            revision: 2,
            members: [
              {...member, 'permissionVersion': '1'},
            ],
          ),
        ]) {
          expect(() => SharedScope.fromJson(value), throwsA(anything));
        }
        expect(
          () => CreateSharedScopeRequest(operationId: 'not-a-uuid'),
          throwsFormatException,
        );
        expect(
          () => SetSharedScopeMemberRequest(
            operationId: _operationId,
            accountId: _memberId,
            role: SharedScopeRole.reader,
            baseRevision: 0,
          ),
          throwsFormatException,
        );
      },
    );

    test('bounds retained membership and revision capacity', () {
      final members = List<Object?>.generate(
        SharedScope.maximumMembers,
        (index) => {
          'accountId': index.toRadixString(16).padLeft(64, '0'),
          'role': 'none',
          'permissionVersion': '2',
        },
      );
      final policy = _policy(
        revision: SharedScope.maximumRevision,
        members: members,
      );
      expect(SharedScope.fromJson(policy).members.length, 128);
      expect(
        () => SharedScope.fromJson({
          ...policy,
          'members': [
            ...members,
            {'accountId': _memberId, 'role': 'none', 'permissionVersion': '2'},
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => SetSharedScopeMemberRequest.create(
          accountId: _memberId,
          role: SharedScopeRole.reader,
          baseRevision: SharedScope.maximumRevision + 1,
        ),
        throwsFormatException,
      );
    });

    test('returned member views cannot be edited by the caller', () {
      final scope = SharedScope.fromJson(
        _policy(
          revision: 2,
          members: [
            {'accountId': _memberId, 'role': 'none', 'permissionVersion': '2'},
          ],
        ),
      );
      expect(scope.members.single.role, SharedScopeRole.none);
      expect(() => scope.members.clear(), throwsUnsupportedError);
    });
  });
}
