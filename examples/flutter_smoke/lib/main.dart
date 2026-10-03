import 'package:flutter/material.dart';

void main() => runApp(const SmokeApp());

class SmokeApp extends StatefulWidget {
  const SmokeApp({super.key, this.runValidation});
  final Future<void> Function()? runValidation;

  @override
  State<SmokeApp> createState() => _SmokeAppState();
}

class _SmokeAppState extends State<SmokeApp> {
  String _status = 'Ready';

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('Cosmos Sync platform validation')),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(_status, key: const ValueKey('validation-status')),
          FilledButton(
            key: const ValueKey('run-validation'),
            onPressed: widget.runValidation == null
                ? null
                : () async {
                    setState(() => _status = 'Running');
                    try {
                      await widget.runValidation!();
                      if (mounted) setState(() => _status = 'Passed');
                    } catch (error) {
                      if (mounted) setState(() => _status = 'Failed: $error');
                    }
                  },
            child: const Text('Run offline validation'),
          ),
        ],
      ),
    ),
  );
}
