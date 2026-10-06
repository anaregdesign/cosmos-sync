import 'dart:async';
import 'dart:convert';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../auth/auth_session_controller.dart';
import '../auth/native_oidc.dart'
    if (dart.library.js_interop) '../auth/web_oidc.dart'
    as platform_auth;
import '../data/workspace_repository.dart';
import 'app_controller.dart';
import 'identity_panel.dart';

class WorkspaceView extends StatefulWidget {
  const WorkspaceView({super.key, required this.controller});
  final AppController controller;

  @override
  State<WorkspaceView> createState() => _WorkspaceViewState();
}

class _WorkspaceViewState extends State<WorkspaceView>
    with WidgetsBindingObserver {
  final _form = GlobalKey<FormState>();
  final _bff = TextEditingController();
  final _issuer = TextEditingController();
  final _clientId = TextEditingController();
  final _redirect = TextEditingController(
    text: platform_auth.defaultRedirectUrl(),
  );
  final _scopes = TextEditingController(text: 'openid offline_access');
  SyncScopeMode _scope = SyncScopeMode.user;
  String? _sharedScopeId;
  bool _localHttp = false;
  String? _formError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final settings = widget.controller.settings;
    if (settings != null) {
      _bff.text = settings.connection.bffUri.toString();
      _scope = settings.connection.scopeMode;
      _sharedScopeId = settings.connection.sharedScopeId;
      _localHttp = settings.connection.allowInsecureLocalhost;
      _issuer.text = settings.oidc.issuer;
      _clientId.text = settings.oidc.clientId;
      _redirect.text = settings.oidc.redirectUrl;
      _scopes.text = settings.oidc.scopes.join(' ');
    }
    _sharedScopeId = widget.controller.sharedScopeId ?? _sharedScopeId;
    if (_sharedScopeId != null) _scope = SyncScopeMode.shared;
    _issuer.addListener(_providerSettingsChanged);
    _clientId.addListener(_providerSettingsChanged);
  }

  void _providerSettingsChanged() => setState(() {});

  List<BrokerProvider> get _brokerProviders {
    final capabilities = widget.controller.brokerCapabilities;
    return capabilities != null &&
            capabilities.matches(
              issuer: _issuer.text.trim(),
              clientId: _clientId.text.trim(),
            )
        ? capabilities.providers
        : const [];
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final workspace = widget.controller.workspace;
    if (state == AppLifecycleState.resumed &&
        workspace.connected &&
        !workspace.offline &&
        !widget.controller.busy) {
      unawaited(workspace.synchronize());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final field in [_bff, _issuer, _clientId, _redirect, _scopes]) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final app = widget.controller;
      final workspace = app.workspace;
      final working = app.busy || workspace.busy;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Cosmos Sync'),
          actions: [
            if (app.auth.isSignedIn || workspace.connected)
              TextButton.icon(
                key: const Key('sign-out'),
                onPressed: app.busy ? null : _signOut,
                icon: const Icon(Icons.logout),
                label: const Text('Sign out'),
              ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (working) const LinearProgressIndicator(),
                if (!workspace.connected) _connectionForm(working),
                if (app.auth.error != null)
                  _notice(app.auth.error!.message, error: true),
                if (_formError != null) _notice(_formError!, error: true),
                if (app.message != null) _notice(app.message!),
                if (workspace.message != null) _notice(workspace.message!),
                if (app.identityCapabilities != null)
                  IdentityPanel(
                    capabilities: app.identityCapabilities!,
                    account: app.identityAccount,
                    registrationRequired: app.registrationRequired,
                    enabled: app.canChangeIdentity,
                    proving: app.auth.state == AuthSessionState.provingIdentity,
                    onRegister: () =>
                        _changeIdentity(IdentityOperation.register),
                    onLink: () => _changeIdentity(IdentityOperation.link),
                    onUnlink: (id) => _changeIdentity(
                      IdentityOperation.unlink,
                      removeIdentityId: id,
                    ),
                    onRecover: _recoverIdentity,
                    onCancel: () => unawaited(app.cancelIdentityProof()),
                  ),
                if (workspace.connected) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            workspace.offline
                                ? 'Offline editing'
                                : 'Live workspace',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${workspace.session!.scopeMode.name} scope • '
                            '${workspace.pending.length} pending • '
                            '${workspace.bootstrapComplete ? 'Cache complete at saved cursor' : 'Initial sync incomplete'}',
                          ),
                          Text(
                            workspace.status?.paused == true
                                ? 'Access paused. Sign out and authenticate again.'
                                : 'Local saves are durable; pending badges remain until server ACK.',
                          ),
                          SwitchListTile.adaptive(
                            key: const Key('offline-switch'),
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Work offline'),
                            subtitle: const Text(
                              'Pause automatic network activity',
                            ),
                            value: workspace.offline,
                            onChanged:
                                working || workspace.status?.paused == true
                                ? null
                                : workspace.setOffline,
                          ),
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            children: [
                              FilledButton.icon(
                                key: const Key('new-document'),
                                onPressed: workspace.canEdit && !app.busy
                                    ? () => _editDocument()
                                    : null,
                                icon: const Icon(Icons.add),
                                label: const Text('New document'),
                              ),
                              OutlinedButton.icon(
                                key: const Key('sync-now'),
                                onPressed:
                                    working ||
                                        workspace.offline ||
                                        workspace.status?.paused == true
                                    ? null
                                    : workspace.synchronize,
                                icon: const Icon(Icons.sync),
                                label: const Text('Sync now'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Documents',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  if (workspace.documents.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        'No cached documents. Create a document or sync.',
                      ),
                    ),
                  for (final document in workspace.documents)
                    Card(
                      child: ListTile(
                        key: Key('document-${document.id}'),
                        title: Text(document.id),
                        subtitle: Text(
                          '${jsonEncode(document.data)}\n'
                          'Server version ${document.version}'
                          '${document.hasConflict ? ' • Conflict' : ''}'
                          '${document.hasPendingWrites ? ' • Pending' : ' • Acknowledged'}',
                        ),
                        isThreeLine: true,
                        onTap: workspace.canEdit && !app.busy
                            ? () => _editDocument(document)
                            : null,
                        trailing: IconButton(
                          key: Key('delete-${document.id}'),
                          tooltip: 'Delete document',
                          onPressed: workspace.canEdit && !app.busy
                              ? () => _deleteDocument(document)
                              : null,
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ),
                    ),
                  if (workspace.pending.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text(
                      'Pending operations',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    for (final mutation in workspace.pending)
                      _pendingCard(mutation, working),
                  ],
                ],
                const SizedBox(height: 24),
                const Text(
                  kIsWeb
                      ? 'Browser sample for Cosmos DB for NoSQL via the BFF. '
                            'MSAL credentials stay in memory. Reload requires a '
                            'new sign-in and online BFF verification before '
                            'reopening IndexedDB. Cached documents are not '
                            'encrypted. Cosmos credentials are never accepted.'
                      : 'Native sample for Cosmos DB for NoSQL via the BFF. '
                            'Credentials remain in OS secure storage; Cosmos credentials '
                            'are never accepted. SQLite documents are not encrypted. '
                            'Offline access cannot observe server revocation until reconnect.',
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _connectionForm(bool working) => Form(
    key: _form,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Connect your workspace',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        const Text(
          kIsWeb
              ? 'Configure an HTTPS BFF and a public Entra SPA client with an '
                    'API scope and this exact same-origin redirect bridge. '
                    'MSAL opens a popup using authorization code and PKCE.'
              : 'Configure an HTTPS BFF and a public native OIDC client with an API '
                    'scope. Sign-in opens the provider in a system browser using PKCE.',
        ),
        const SizedBox(height: 16),
        _field(_bff, 'BFF URL', 'bff-url', enabled: !working),
        _field(_issuer, 'OIDC issuer URL', 'oidc-issuer', enabled: !working),
        _field(_clientId, 'Public client ID', 'oidc-client', enabled: !working),
        _field(
          _redirect,
          kIsWeb ? 'Registered Web redirect bridge' : 'Native callback URL',
          'oidc-redirect',
          enabled: false,
        ),
        _field(
          _scopes,
          'Scopes (space separated, including your API scope)',
          'oidc-scopes',
          enabled: !working,
        ),
        DropdownButtonFormField<SyncScopeMode>(
          key: const Key('scope-mode'),
          initialValue: _scope,
          decoration: const InputDecoration(labelText: 'Authorized scope'),
          items: _sharedScopeId != null
              ? const [
                  DropdownMenuItem(
                    value: SyncScopeMode.shared,
                    child: Text('Shared workspace (owner-provided)'),
                  ),
                ]
              : const [
                  DropdownMenuItem(
                    value: SyncScopeMode.user,
                    child: Text('Personal'),
                  ),
                  DropdownMenuItem(
                    value: SyncScopeMode.tenant,
                    child: Text('Legacy tenant scope'),
                  ),
                ],
          onChanged: working || _sharedScopeId != null
              ? null
              : (value) => setState(() => _scope = value!),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Allow loopback HTTP for local development'),
          subtitle: const Text(
            'Only localhost / 127.0.0.1 / ::1; provider still requires HTTPS',
          ),
          value: _localHttp,
          onChanged: working
              ? null
              : (value) => setState(() => _localHttp = value!),
        ),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              key: const Key('sign-in'),
              onPressed: working || widget.controller.auth.isSignedIn
                  ? null
                  : () => _signIn(),
              icon: const Icon(Icons.login),
              label: const Text('Save and sign in'),
            ),
            for (final provider in _brokerProviders)
              OutlinedButton(
                key: Key('sign-in-${provider.name}'),
                onPressed: working || widget.controller.auth.isSignedIn
                    ? null
                    : () => _signIn(provider: provider),
                child: Text(
                  'Continue with ${provider == BrokerProvider.google ? 'Google' : 'Apple'}',
                ),
              ),
            OutlinedButton(
              key: const Key('connect-online'),
              onPressed: widget.controller.canConnect
                  ? () => widget.controller.connect()
                  : null,
              child: const Text('Connect online'),
            ),
            OutlinedButton(
              key: const Key('connect-offline'),
              onPressed:
                  widget.controller.canConnect &&
                      widget.controller.auth.restoredSession
                  ? () => widget.controller.connect(offline: true)
                  : null,
              child: const Text('Open verified cache offline'),
            ),
            if (widget.controller.auth.state == AuthSessionState.authorizing)
              TextButton(
                key: const Key('cancel-sign-in'),
                onPressed: widget.controller.auth.cancelSignIn,
                child: const Text('Cancel sign-in'),
              ),
          ],
        ),
        Text('Authentication: ${widget.controller.auth.state.name}'),
        const SizedBox(height: 12),
      ],
    ),
  );

  Widget _field(
    TextEditingController controller,
    String label,
    String key, {
    required bool enabled,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      key: Key(key),
      controller: controller,
      enabled: enabled,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      validator: (value) =>
          value == null || value.trim().isEmpty ? 'Required' : null,
    ),
  );

  Widget _notice(String text, {bool error = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Text(
      text,
      key: error ? const Key('error-message') : const Key('status-message'),
      style: error
          ? TextStyle(color: Theme.of(context).colorScheme.error)
          : null,
    ),
  );

  Widget _pendingCard(PendingMutation mutation, bool working) {
    final discardable =
        mutation.state != MutationState.queued || mutation.attempts == 0;
    final conflict = mutation.state == MutationState.conflict;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${mutation.documentId} • ${mutation.kind.name} • ${mutation.state.name}',
            ),
            Text(
              'Attempts ${mutation.attempts} • ${mutation.errorCode ?? 'not sent'}',
            ),
            if (mutation.nextAttemptAt != null)
              Text('Retry after ${mutation.nextAttemptAt!.toLocal()}'),
            if (mutation.data != null)
              Text('Local: ${jsonEncode(mutation.data)}'),
            if (conflict)
              const Text(
                'Keep local creates an explicit new operation against the observed '
                'server version. Use server discards this local operation; later queued edits remain.',
              ),
            if (mutation.errorCode == 'scope_capacity_exceeded')
              const Text(
                'The scope reached its server capacity. Contact the operator. '
                'The original operation remains pending; do not create a replacement.',
              ),
            if (!discardable)
              const Text(
                'An attempted write may have committed. Its original operation ID '
                'must be replayed; discard is unavailable.',
              ),
            Wrap(
              spacing: 12,
              children: [
                if (conflict)
                  TextButton(
                    key: Key('keep-local-${mutation.documentId}'),
                    onPressed: working
                        ? null
                        : () => widget.controller.workspace.keepLocal(mutation),
                    child: const Text('Keep local and retry'),
                  ),
                if (discardable)
                  TextButton(
                    key: Key('discard-${mutation.documentId}'),
                    onPressed: working
                        ? null
                        : () => widget.controller.workspace.useServer(mutation),
                    child: Text(
                      conflict ? 'Use server' : 'Discard local operation',
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _signIn({BrokerProvider? provider}) {
    if (!_form.currentState!.validate()) return;
    try {
      if (kIsWeb
          ? _redirect.text.trim() != platform_auth.defaultRedirectUrl()
          : Uri.parse(_redirect.text.trim()).scheme !=
                'com.anaregdesign.cosmossync') {
        throw const FormatException('Callback does not match this build.');
      }
      final settings = AppSettings(
        connection: ConnectionConfig(
          bffUri: Uri.parse(_bff.text.trim()),
          scopeMode: _scope,
          sharedScopeId: _scope == SyncScopeMode.shared ? _sharedScopeId : null,
          allowInsecureLocalhost: _localHttp,
        ),
        oidc: OidcConfig(
          issuer: _issuer.text.trim(),
          clientId: _clientId.text.trim(),
          redirectUrl: _redirect.text.trim(),
          scopes: _scopes.text.trim().split(RegExp(r'\s+')),
          browser: kIsWeb,
        ),
      );
      setState(() => _formError = null);
      unawaited(widget.controller.signIn(settings, provider: provider));
    } catch (_) {
      setState(
        () => _formError =
            'Use valid HTTPS issuer/BFF URLs and an API scope. '
            'The callback must match the registered native scheme.',
      );
    }
  }

  Future<void> _editDocument([DocumentSnapshot? document]) async {
    final result = await showDialog<_DocumentEdit>(
      context: context,
      builder: (_) => _DocumentEditor(document: document),
    );
    if (result != null) {
      await widget.controller.workspace.put(result.id, result.data);
    }
  }

  Future<void> _deleteDocument(DocumentSnapshot document) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete ${document.id}?'),
        content: const Text(
          'The deletion is saved locally and synchronized when online.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm-delete'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.controller.workspace.delete(document.id);
    }
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sign out and clear this device?'),
        content: Text(
          'Cached documents and ${widget.controller.workspace.pending.length} '
          'pending operation(s) will be removed after in-flight requests finish. '
          'Unsent edits will be lost.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm-sign-out'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out and clear'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.controller.signOut();
  }

  Future<bool> _confirmIdentity(
    String title,
    String detail,
    String key,
  ) async =>
      await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(title),
          content: Text(
            '$detail\n\nCached documents and '
            '${widget.controller.workspace.pending.length} pending operation(s) '
            'will be removed after in-flight work drains. Unsent edits will be lost. '
            'Server-owned documents are not moved or deleted.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: Key(key),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue and clear local data'),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _changeIdentity(
    IdentityOperation operation, {
    String? removeIdentityId,
  }) async {
    final confirmed = await _confirmIdentity(
      switch (operation) {
        IdentityOperation.register => 'Register a new account?',
        IdentityOperation.link => 'Link an independent identity?',
        IdentityOperation.unlink => 'Remove this identity?',
      },
      switch (operation) {
        IdentityOperation.register =>
          'Authenticate this credential freshly. Registration does not recover or merge an existing account.',
        IdentityOperation.link =>
          'Authenticate the current credential, then the independent identity. Both proofs must be approved by the BFF.',
        IdentityOperation.unlink =>
          'Authenticate the current credential, then a remaining linked credential. Removing the current credential requires a new sign-in.',
      },
      'confirm-${operation.name}',
    );
    if (!confirmed || !mounted) return;
    final app = widget.controller;
    switch (operation) {
      case IdentityOperation.register:
        await app.registerAccount(discardPending: true);
      case IdentityOperation.link:
        await app.linkIdentity(discardPending: true);
      case IdentityOperation.unlink:
        await app.unlinkIdentity(removeIdentityId!, discardPending: true);
    }
  }

  Future<void> _recoverIdentity() async {
    if (await _confirmIdentity(
          'Use a remaining linked identity?',
          'Sign out locally, then sign in online with an existing linked credential. '
              'If every credential is lost, operator review is required; no email-based recovery exists.',
          'confirm-recover',
        ) &&
        mounted) {
      await widget.controller.recoverWithRemainingIdentity(
        discardPending: true,
      );
    }
  }
}

class _DocumentEdit {
  const _DocumentEdit(this.id, this.data);
  final String id;
  final Map<String, Object?> data;
}

class _DocumentEditor extends StatefulWidget {
  const _DocumentEditor({this.document});
  final DocumentSnapshot? document;
  @override
  State<_DocumentEditor> createState() => _DocumentEditorState();
}

class _DocumentEditorState extends State<_DocumentEditor> {
  late final _id = TextEditingController(text: widget.document?.id ?? '');
  late final _json = TextEditingController(
    text: const JsonEncoder.withIndent(
      '  ',
    ).convert(widget.document?.data ?? {'title': ''}),
  );
  String? _error;
  @override
  void dispose() {
    _id.dispose();
    _json.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.document == null ? 'New document' : 'Edit document'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('document-id'),
              controller: _id,
              enabled: widget.document == null,
              decoration: const InputDecoration(labelText: 'Document ID'),
            ),
            TextField(
              key: const Key('document-json'),
              controller: _json,
              maxLines: 10,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'JSON object'),
            ),
            if (_error != null) Text(_error!, key: const Key('document-error')),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('save-document'),
        onPressed: _save,
        child: const Text('Save locally'),
      ),
    ],
  );

  void _save() {
    try {
      final id = _id.text.trim();
      if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(id)) {
        throw const FormatException();
      }
      final decoded = jsonDecode(_json.text);
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      final data = immutableJson(decoded.cast<String, Object?>());
      Navigator.pop(context, _DocumentEdit(id, data));
    } catch (_) {
      setState(
        () => _error = 'Use a valid document ID and a portable JSON object.',
      );
    }
  }
}
