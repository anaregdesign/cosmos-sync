import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../auth/auth_session_controller.dart';
import '../data/settings_store_native.dart';
import '../data/workspace_repository.dart';
import '../ui/app_controller.dart';
import '../ui/workspace_controller.dart';

Future<AppController> createController() async {
  final support = await getApplicationSupportDirectory();
  final root = Directory(p.join(support.path, 'cosmos-sync-example'));
  const sharedScopeId = String.fromEnvironment('COSMOS_SYNC_SHARED_SCOPE_ID');
  const brokerConfig = String.fromEnvironment(
    'COSMOS_SYNC_ENTRA_BROKER_CAPABILITIES',
  );
  return AppController(
    auth: AuthSessionController(),
    workspace: WorkspaceController(
      repository: WorkspaceRepository(
        directory: Directory(p.join(root.path, 'workspaces')),
      ),
    ),
    settingsStore: FileSettingsStore(
      File(p.join(root.path, 'connection.json')),
    ),
    sharedScopeId: sharedScopeId.isEmpty ? null : sharedScopeId,
    brokerCapabilities: brokerConfig.isEmpty
        ? null
        : EntraBrokerCapabilities.fromJsonString(brokerConfig),
  );
}
