/// Manual directory SDK acceptance with a previously verified API credential.
/// This target is not a provider login, native UI or additional-identity test.
library;

import 'dart:io';

import 'package:cosmos_sync/cosmos_sync.dart';

import 'support/recorded_data_journey.dart';
import 'hosted_azure_live.dart' show HostedBudgetClient, HostedManualControl;

Future<void> main() async {
  try {
    await run();
    stdout.writeln(
      'COSMOS_SYNC_DIRECTORY_SDK_PASS sqlite=true auth=recorded-api',
    );
  } catch (_) {
    stderr.writeln('COSMOS_SYNC_DIRECTORY_SDK_FAILED');
    exitCode = 1;
  }
}

Future<void> run() async {
  final control = HostedManualControl(
    Uri.parse(Platform.environment['COSMOS_SYNC_DIRECTORY_CONTROL_URL'] ?? ''),
  );
  final fixture = await control.configuration();
  _check(
    fixture['protocolVersion'] == 2 &&
        fixture['authorizationMode'] == 'directory' &&
        fixture['authenticationMode'] == 'recorded-api-token',
  );
  final endpoint = Uri.parse(fixture['endpoint'] as String);
  final token = fixture['accessToken'] as String;
  HttpSyncTransport transport(bool Function() allowed) => HttpSyncTransport(
    baseUri: endpoint,
    tokenProvider: () async => token,
    requestTimeout: const Duration(seconds: 15),
    client: HostedBudgetClient(endpoint, control, allowed),
  );
  final identity = transport(() => true);
  late final SessionInfo session;
  try {
    session = await verifyDirectoryIdentity(
      transport: identity,
      issuer: fixture['issuer'] as String,
      clientId: fixture['clientId'] as String,
      callback: fixture['callback'] as String,
      namespace: fixture['namespace'] as String,
      stage: control.stage,
    );
  } finally {
    identity.close();
  }
  await RecordedDataJourney(
    directory: Directory(fixture['cacheDirectory'] as String),
    documentId: fixture['documentId'] as String,
    directoryMode: true,
    purgeOnSignout: true,
    initialVerifiedSession: session,
    stage: control.stage,
    transportFactory: (allowed, _) => transport(allowed),
  ).run();
}

void _check(bool condition) {
  if (!condition) throw StateError('Directory acceptance contract failed.');
}
