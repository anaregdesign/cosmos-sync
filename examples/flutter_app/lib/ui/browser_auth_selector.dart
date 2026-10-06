import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../auth/oidc.dart';

class BrowserAuthSelector extends StatelessWidget {
  const BrowserAuthSelector({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final BrowserAuthAdapter value;
  final ValueChanged<BrowserAuthAdapter>? onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<BrowserAuthAdapter>(
          key: const Key('browser-auth-adapter'),
          initialValue: value,
          decoration: const InputDecoration(
            labelText: 'Browser authentication adapter',
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(
              value: BrowserAuthAdapter.entra,
              child: Text('Entra / External ID (MSAL)'),
            ),
            DropdownMenuItem(
              value: BrowserAuthAdapter.oidc,
              child: Text('Generic OIDC (Code + PKCE)'),
            ),
          ],
          onChanged: onChanged == null
              ? null
              : (selected) {
                  if (selected != null) onChanged!(selected);
                },
        ),
        const SizedBox(height: 8),
        Text(
          value == BrowserAuthAdapter.entra
              ? 'Use the registered Entra SPA client and MSAL callback.'
              : 'Use a browser-capable HTTPS OIDC public client with a BFF API '
                    'scope and the OIDC callback. Entra directory linking is '
                    'not supported by this adapter.',
        ),
      ],
    ),
  );
}

@Preview(
  name: 'Generic browser OIDC',
  group: 'Authentication',
  size: Size(390, 220),
)
Widget browserAuthSelectorPreview() => MaterialApp(
  home: Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: BrowserAuthSelector(
        value: BrowserAuthAdapter.oidc,
        onChanged: browserAuthPreviewSelection,
      ),
    ),
  ),
);

void browserAuthPreviewSelection(BrowserAuthAdapter _) {}
