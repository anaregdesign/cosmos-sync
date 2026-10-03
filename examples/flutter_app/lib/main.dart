import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'auth/auth_session_controller.dart';
import 'data/workspace_repository.dart';
import 'ui/app_controller.dart';
import 'ui/workspace_controller.dart';
import 'ui/workspace_view.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  final root = Directory(p.join(support.path, 'cosmos-sync-example'));
  final controller = AppController(
    auth: AuthSessionController(),
    workspace: WorkspaceController(
      repository: WorkspaceRepository(
        directory: Directory(p.join(root.path, 'workspaces')),
      ),
    ),
    settingsFile: File(p.join(root.path, 'connection.json')),
  );
  await controller.initialize();
  runApp(CosmosSyncApp(controller: controller));
}

class CosmosSyncApp extends StatelessWidget {
  const CosmosSyncApp({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Cosmos Sync',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff365cce)),
      useMaterial3: true,
    ),
    home: WorkspaceView(controller: controller),
  );
}
