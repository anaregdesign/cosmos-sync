import 'dart:convert';

import 'authorization.dart';

enum IdentityOperation { register, link, unlink }

/// Ephemeral OIDC proof for a dedicated identity endpoint, never a cache owner.
/// Obtain both tokens from fresh SDK-managed code/PKCE authentication.
class FreshIdentityProof {
  FreshIdentityProof({required this.accessToken, required this.idToken}) {
    if (!_token(accessToken, 32768) || !_token(idToken, 16384)) {
      throw const FormatException('Invalid fresh identity proof.');
    }
  }

  final String accessToken;
  final String idToken;

  Map<String, Object?> toJson() => {
    'accessToken': accessToken,
    'idToken': idToken,
  };

  @override
  String toString() => 'FreshIdentityProof([redacted])';
}

/// An exact operator-approved issuer/client/callback target from the BFF.
class IdentityProofTarget {
  IdentityProofTarget({
    required this.issuer,
    required this.provider,
    required this.namespace,
    required this.clientId,
    required this.callback,
  }) {
    final authority = Uri.tryParse(issuer);
    final redirect = Uri.tryParse(callback);
    if (authority == null ||
        authority.scheme != 'https' ||
        authority.host.isEmpty ||
        authority.userInfo.isNotEmpty ||
        authority.hasQuery ||
        authority.hasFragment ||
        !_text(issuer, 512) ||
        !{'entra', 'google', 'apple'}.contains(provider) ||
        !_text(namespace, 128) ||
        !RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        ).hasMatch(clientId) ||
        redirect == null ||
        redirect.host.isEmpty ||
        redirect.userInfo.isNotEmpty ||
        redirect.hasQuery ||
        redirect.hasFragment ||
        !_text(callback, 2048) ||
        !(redirect.scheme == 'https' ||
            redirect.scheme == 'http' &&
                {'localhost', '127.0.0.1', '::1'}.contains(redirect.host) ||
            redirect.scheme.contains('.'))) {
      throw const FormatException('Invalid approved identity target.');
    }
  }

  factory IdentityProofTarget.fromJson(Map<String, Object?> json) =>
      IdentityProofTarget(
        issuer: json['issuer'] as String,
        provider: json['provider'] as String,
        namespace: json['namespace'] as String,
        clientId: json['clientId'] as String,
        callback: json['callback'] as String,
      );

  final String issuer;
  final String provider;
  final String namespace;
  final String clientId;
  final String callback;

  bool sameTarget(IdentityProofTarget other) =>
      issuer == other.issuer &&
      provider == other.provider &&
      namespace == other.namespace &&
      clientId == other.clientId &&
      callback == other.callback;

  bool matchesClient(String issuer, String clientId, String callback) =>
      this.issuer == issuer &&
      this.clientId == clientId &&
      this.callback == callback;
}

/// Discovery does not prove a provider connection or a successful fresh login.
class IdentityCapabilities {
  IdentityCapabilities({
    required List<IdentityProofTarget> targets,
    required this.freshAuthenticationSeconds,
    required this.maximumIdentities,
    required this.recovery,
    required this.deletion,
    required this.migration,
  }) : targets = List.unmodifiable(targets) {
    if (targets.isEmpty ||
        targets.length > 16 ||
        freshAuthenticationSeconds != 300 ||
        maximumIdentities != 8 ||
        recovery != 'remaining-identity-only' ||
        deletion != 'operator-review-required' ||
        migration != 'operator-review-required') {
      throw const FormatException('Unsupported identity capabilities.');
    }
    for (var index = 0; index < targets.length; index++) {
      if (targets.take(index).any(targets[index].sameTarget)) {
        throw const FormatException('Duplicate approved identity target.');
      }
    }
  }

  factory IdentityCapabilities.fromJson(Map<String, Object?> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported identity capabilities.');
    }
    return IdentityCapabilities(
      targets: (json['targets'] as List)
          .map((value) => IdentityProofTarget.fromJson((value as Map).cast()))
          .toList(growable: false),
      freshAuthenticationSeconds: json['freshAuthenticationSeconds'] as int,
      maximumIdentities: json['maximumIdentities'] as int,
      recovery: json['recovery'] as String,
      deletion: json['deletion'] as String,
      migration: json['migration'] as String,
    );
  }

  final List<IdentityProofTarget> targets;
  final int freshAuthenticationSeconds;
  final int maximumIdentities;
  final String recovery;
  final String deletion;
  final String migration;

  IdentityProofTarget targetFor({
    required String issuer,
    required String clientId,
    required String callback,
  }) {
    final matches = targets.where(
      (target) => target.matchesClient(issuer, clientId, callback),
    );
    if (matches.length != 1) {
      throw const FormatException('The OIDC client has no approved target.');
    }
    return matches.single;
  }
}

class IdentityChallenge {
  IdentityChallenge({
    required this.challenge,
    required this.operation,
    required this.expiresAt,
    required this.target,
  }) {
    validateAuthorizationId(challenge, 'challenge');
  }

  factory IdentityChallenge.fromJson(Map<String, Object?> json) =>
      IdentityChallenge(
        challenge: json['challenge'] as String,
        operation: IdentityOperation.values.byName(json['operation'] as String),
        expiresAt: DateTime.parse(json['expiresAt'] as String).toUtc(),
        target: IdentityProofTarget.fromJson((json['target'] as Map).cast()),
      );

  final String challenge;
  final IdentityOperation operation;
  final DateTime expiresAt;
  final IdentityProofTarget target;

  @override
  String toString() => 'IdentityChallenge(${operation.name}, [redacted])';
}

class AccountIdentityCredential {
  AccountIdentityCredential({
    required this.identityId,
    required this.provider,
  }) {
    validateAuthorizationId(identityId, 'identityId');
    if (!{'entra', 'google', 'apple'}.contains(provider)) {
      throw const FormatException('Unsupported identity provider.');
    }
  }

  factory AccountIdentityCredential.fromJson(Map<String, Object?> json) =>
      AccountIdentityCredential(
        identityId: json['identityId'] as String,
        provider: json['provider'] as String,
      );

  final String identityId;
  final String provider;
}

/// An immutable operation result, not an API credential or a verified data scope.
/// Discover a new `/session` before resuming data after a generation change.
class IdentityAccount {
  IdentityAccount({
    required this.account,
    required this.identityGeneration,
    required List<AccountIdentityCredential> identities,
    this.currentIdentityId,
  }) : identities = List.unmodifiable(identities) {
    final ids = <String>{};
    if (identityGeneration < 1 ||
        identityGeneration > 10000 ||
        identities.isEmpty ||
        identities.length > 8 ||
        identities.any((identity) => !ids.add(identity.identityId)) ||
        currentIdentityId != null && !ids.contains(currentIdentityId)) {
      throw const FormatException('Invalid identity account result.');
    }
  }

  factory IdentityAccount.fromJson(Map<String, Object?> json) {
    if (json.containsKey('currentIdentityId') &&
        json['currentIdentityId'] is! String) {
      throw const FormatException('Invalid current identity.');
    }
    return IdentityAccount(
      account: BuiltinAccount.fromJson(json),
      identityGeneration: json['identityGeneration'] as int,
      currentIdentityId: json['currentIdentityId'] as String?,
      identities: (json['identities'] as List)
          .map(
            (value) =>
                AccountIdentityCredential.fromJson((value as Map).cast()),
          )
          .toList(growable: false),
    );
  }

  final BuiltinAccount account;
  final int identityGeneration;
  final String? currentIdentityId;
  final List<AccountIdentityCredential> identities;
}

bool _text(String value, int maximum) =>
    value.isNotEmpty &&
    utf8.encode(value).length <= maximum &&
    value == value.trim() &&
    !value.contains(RegExp(r'[\x00\r\n\t]'));

bool _token(String value, int maximum) =>
    value.isNotEmpty &&
    value.length <= maximum &&
    RegExp(r'^[A-Za-z0-9\-._~+/]+=*$').hasMatch(value);
