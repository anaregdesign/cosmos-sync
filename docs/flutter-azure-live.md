# Manual Flutter UI to actual Cosmos validation

This isolated macOS integration target exercises the normal Flutter UI,
controllers, HTTP sync transport and SQLite cache through two production TLS
BFF processes backed by the owner-approved Cosmos DB for NoSQL container.
It uses a **recorded real Entra API access JWT**, reverified before execution.
It does not claim fresh login, actual provider refresh, Keychain restoration,
OS process restart or distinct-user isolation. Those native authentication
operations have a [separate target](native-auth-live.md).

After the owner-selected environment, narrow data role and container metadata
have been read back, run from the repository root with the approved isolated
Azure CLI context already selected:

```sh
python3 tools/flutter_azure_live.py \
  --manifest .cache/azure-verification/environment.local.json \
  --execute-approved-ui-contract
```

`FLUTTER_BIN`/`--flutter-bin` selects the installed Flutter SDK. The manifest and
JWT must remain private local files. The runner verifies the captured JWT's
signature, issuer, dedicated API audience, delegated scope, times, selected
tenant and approved signed account identifier before deriving the API subject.
That subject must match the exact owner-approved manifest grant. No token or
owner identifier is embedded in a dart-define, asset, repository file or log.

The sole fixture endpoint is a random-capability URL on `127.0.0.1`; only the
separate test target receives the recorded JWT. Its injected `IOClient` trusts
only this run's owned TLS certificate, verifies the server normally, rejects
other origins and disables redirects. It changes no system trust store and has
no `badCertificateCallback`. The ordinary application target remains unchanged.

The target writes a unique document in the approved user's **personal** scope,
allows preexisting documents, reopens its durable pending edit offline, reconnects
and waits for server acknowledgment. It updates the document, reads it through
the second BFF, then verifies cache/outbox purge on a permission-generation
downgrade and grant revocation. Only this run's private local grant file changes.
The queued edits used for purge checks must never become accepted cloud writes.
Local signout and cleanup remove only the new test cache and memory credentials.

The host permits at most the manifest's request budget (never above 50), three
mutation attempts and 120 seconds of live BFF activity. Two new accepted
mutations are expected. The absolute deadline stops the owned BFF processes;
failure preserves a private partial report without claiming completion. Azure
resources, documents, journals and receipts are retained and never deleted by
this runner.

`.cache/azure-ui-live/latest.local.json` points to a 0700 private run directory.
Logs, configuration and proof remain private (0600). The runner removes its
own recorded JWT copy after completion or failure; the original approved native
and Azure-contract files belong to their coordinators. Share only the
nonidentifying proof. This harness does not prove hosted
deployment, physical-device Azure connectivity or multi-account isolation.
