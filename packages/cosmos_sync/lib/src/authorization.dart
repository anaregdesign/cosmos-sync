import 'dart:math';

/// An account registered by the BFF from a verified issuer and subject.
/// No email, provider role or client-selected owner establishes this identity.
class BuiltinAccount {
  BuiltinAccount({required this.accountId, required this.personalScopeId}) {
    validateAuthorizationId(accountId, 'accountId');
    validateAuthorizationId(personalScopeId, 'personalScopeId');
  }

  factory BuiltinAccount.fromJson(Map<String, Object?> json) => BuiltinAccount(
    accountId: json['accountId'] as String,
    personalScopeId: json['personalScopeId'] as String,
  );

  final String accountId;
  final String personalScopeId;
}

/// Shared data permissions. The fixed owner is managed by the BFF separately.
enum SharedScopeRole { reader, writer, none }

class SharedScopeMember {
  SharedScopeMember({
    required this.accountId,
    required this.role,
    required this.permissionVersion,
  }) {
    validateAuthorizationId(accountId, 'accountId');
    final revision = int.tryParse(permissionVersion);
    if (!RegExp(r'^[1-9][0-9]*$').hasMatch(permissionVersion) ||
        revision == null ||
        revision < 2 ||
        revision > SharedScope.maximumRevision) {
      throw const FormatException('Invalid member permission version.');
    }
  }

  factory SharedScopeMember.fromJson(Map<String, Object?> json) =>
      SharedScopeMember(
        accountId: json['accountId'] as String,
        role: SharedScopeRole.values.byName(json['role'] as String),
        permissionVersion: json['permissionVersion'] as String,
      );

  final String accountId;
  final SharedScopeRole role;
  final String permissionVersion;
}

/// An owner-only policy view. Member lists are immutable; [revision] is the
/// optimistic concurrency base for the next edit, not a document version.
class SharedScope {
  /// Preview capacity includes retained revoked members and management history.
  static const maximumMembers = 128;
  static const maximumRevision = 10000;

  SharedScope({
    required this.scopeId,
    required this.ownerAccountId,
    required this.revision,
    required List<SharedScopeMember> members,
  }) : members = List.unmodifiable(members) {
    validateAuthorizationId(scopeId, 'scopeId');
    validateAuthorizationId(ownerAccountId, 'ownerAccountId');
    _validateRevision(revision);
    if (members.length > maximumMembers) {
      throw const FormatException('Shared scope membership exceeds capacity.');
    }
    final accounts = <String>{};
    for (final member in members) {
      if (member.accountId == ownerAccountId ||
          !accounts.add(member.accountId) ||
          int.parse(member.permissionVersion) > revision) {
        throw const FormatException('Invalid shared scope membership.');
      }
    }
  }

  factory SharedScope.fromJson(Map<String, Object?> json) => SharedScope(
    scopeId: json['scopeId'] as String,
    ownerAccountId: json['ownerAccountId'] as String,
    revision: json['revision'] as int,
    members: (json['members'] as List)
        .map((value) => SharedScopeMember.fromJson((value as Map).cast()))
        .toList(),
  );

  final String scopeId;
  final String ownerAccountId;
  final int revision;
  final List<SharedScopeMember> members;
}

/// Persist this request before sending if it must survive an application exit.
/// A timeout has an unknown outcome: retry this exact request, never a new ID.
class CreateSharedScopeRequest {
  CreateSharedScopeRequest({required this.operationId}) {
    _validateOperationId(operationId);
  }

  factory CreateSharedScopeRequest.create() =>
      CreateSharedScopeRequest(operationId: _newOperationId());

  factory CreateSharedScopeRequest.fromJson(Map<String, Object?> json) =>
      CreateSharedScopeRequest(operationId: json['operationId'] as String);

  final String operationId;

  Map<String, Object?> toJson() => {'operationId': operationId};
}

/// An immutable owner edit. `none` revokes access. No operation may change the
/// fixed owner or grant a client permission to manage its own membership.
class SetSharedScopeMemberRequest {
  SetSharedScopeMemberRequest({
    required this.operationId,
    required this.accountId,
    required this.role,
    required this.baseRevision,
  }) {
    _validateOperationId(operationId);
    validateAuthorizationId(accountId, 'accountId');
    _validateRevision(baseRevision);
  }

  factory SetSharedScopeMemberRequest.create({
    required String accountId,
    required SharedScopeRole role,
    required int baseRevision,
  }) => SetSharedScopeMemberRequest(
    operationId: _newOperationId(),
    accountId: accountId,
    role: role,
    baseRevision: baseRevision,
  );

  factory SetSharedScopeMemberRequest.fromJson(Map<String, Object?> json) =>
      SetSharedScopeMemberRequest(
        operationId: json['operationId'] as String,
        accountId: json['accountId'] as String,
        role: SharedScopeRole.values.byName(json['role'] as String),
        baseRevision: json['baseRevision'] as int,
      );

  final String operationId;
  final String accountId;
  final SharedScopeRole role;
  final int baseRevision;

  Map<String, Object?> toJson() => {
    'operationId': operationId,
    'accountId': accountId,
    'role': role.name,
    'baseRevision': baseRevision,
  };
}

/// Validates opaque BFF-generated identifiers before using them in a URL.
void validateAuthorizationId(String value, String name) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw ArgumentError.value(value, name, 'Expected a BFF-issued identifier.');
  }
}

void _validateRevision(int value) {
  if (value < 1 || value > SharedScope.maximumRevision) {
    throw const FormatException('Invalid membership revision.');
  }
}

void _validateOperationId(String value) {
  if (!RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  ).hasMatch(value)) {
    throw const FormatException('Expected a UUID operation ID.');
  }
}

String _newOperationId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
