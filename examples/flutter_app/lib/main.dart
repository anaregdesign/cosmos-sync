import 'package:flutter/material.dart';

import 'platform/app_platform_native.dart'
    if (dart.library.js_interop) 'platform/app_platform_web.dart'
    as platform;
import 'ui/app_controller.dart';
import 'ui/workspace_view.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = await platform.createController();
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
