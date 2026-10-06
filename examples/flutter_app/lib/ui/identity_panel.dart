import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

/// Online account actions are advertised only by a verified BFF capability.
class IdentityPanel extends StatelessWidget {
  const IdentityPanel({
    super.key,
    required this.capabilities,
    required this.account,
    required this.registrationRequired,
    required this.enabled,
    required this.proving,
    required this.onRegister,
    required this.onLink,
    required this.onUnlink,
    required this.onRecover,
    required this.onCancel,
  });

  final IdentityCapabilities capabilities;
  final IdentityAccount? account;
  final bool registrationRequired;
  final bool enabled;
  final bool proving;
  final VoidCallback onRegister;
  final VoidCallback onLink;
  final ValueChanged<String> onUnlink;
  final VoidCallback onRecover;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final current = account;
    return Card(
      key: const Key('identity-panel'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Account identities',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Online actions require fresh browser authentication. '
              'Email and provider navigation never link accounts.',
            ),
            if (!enabled && !proving)
              const Text(
                'Connect online with a supported proof adapter before changing identities.',
              ),
            if (registrationRequired)
              FilledButton(
                key: const Key('register-account'),
                onPressed: enabled ? onRegister : null,
                child: const Text('Register a new account'),
              ),
            if (current != null) ...[
              const SizedBox(height: 8),
              Text(
                'Account ${current.account.accountId.substring(0, 12)}... '
                '/ identity generation ${current.identityGeneration}',
              ),
              for (final identity in current.identities)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      Text(
                        '${identity.provider} / ${identity.identityId.substring(0, 12)}...'
                        '${identity.identityId == current.currentIdentityId ? ' (current)' : ''}',
                      ),
                      OutlinedButton(
                        key: Key('unlink-${identity.identityId}'),
                        onPressed: enabled && current.identities.length > 1
                            ? () => onUnlink(identity.identityId)
                            : null,
                        child: const Text('Remove identity'),
                      ),
                    ],
                  ),
                ),
              OutlinedButton(
                key: const Key('link-identity'),
                onPressed:
                    enabled &&
                        current.identities.length <
                            capabilities.maximumIdentities
                    ? onLink
                    : null,
                child: const Text('Link an independent identity'),
              ),
              if (current.identities.length == 1)
                const Text('The last credential cannot be removed.'),
            ],
            TextButton(
              key: const Key('recover-account'),
              onPressed: enabled ? onRecover : null,
              child: const Text('Sign in with a remaining identity'),
            ),
            const Text(
              'Recovery requires an already linked credential. '
              'Account deletion and data migration require operator review.',
            ),
            if (proving)
              TextButton(
                key: const Key('cancel-identity-proof'),
                onPressed: onCancel,
                child: const Text('Cancel identity authentication'),
              ),
          ],
        ),
      ),
    );
  }
}

@Preview(
  name: 'Linked account',
  group: 'Identity lifecycle',
  size: Size(390, 550),
)
Widget identityPanelPreview() => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: IdentityPanel(
        capabilities: IdentityCapabilities(
          targets: [
            IdentityProofTarget(
              issuer: 'https://issuer.example.test/tenant',
              provider: 'entra',
              namespace: 'preview-v1',
              clientId: '22222222-2222-4222-8222-222222222222',
              callback: 'com.anaregdesign.cosmossync://auth/oauthredirect',
            ),
          ],
          freshAuthenticationSeconds: 300,
          maximumIdentities: 8,
          recovery: 'remaining-identity-only',
          deletion: 'operator-review-required',
          migration: 'operator-review-required',
        ),
        account: IdentityAccount(
          account: BuiltinAccount(
            accountId: 'a' * 64,
            personalScopeId: 'b' * 64,
          ),
          identityGeneration: 2,
          currentIdentityId: 'c' * 64,
          identities: [
            AccountIdentityCredential(identityId: 'c' * 64, provider: 'entra'),
            AccountIdentityCredential(identityId: 'd' * 64, provider: 'entra'),
          ],
        ),
        registrationRequired: false,
        enabled: true,
        proving: false,
        onRegister: identityPreviewAction,
        onLink: identityPreviewAction,
        onUnlink: identityPreviewUnlink,
        onRecover: identityPreviewAction,
        onCancel: identityPreviewAction,
      ),
    ),
  ),
);

void identityPreviewAction() {}
void identityPreviewUnlink(String _) {}
