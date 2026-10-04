import '../auth/auth_session_controller.dart';
import '../data/settings_store_web.dart';
import '../data/workspace_repository_web.dart';
import '../ui/app_controller.dart';
import '../ui/workspace_controller.dart';

Future<AppController> createController() async {
  const sharedScopeId = String.fromEnvironment('COSMOS_SYNC_SHARED_SCOPE_ID');
  return AppController(
    auth: AuthSessionController(),
    workspace: WorkspaceController(repository: WorkspaceRepository()),
    settingsStore: const BrowserSettingsStore(),
    sharedScopeId: sharedScopeId.isEmpty ? null : sharedScopeId,
  );
}
