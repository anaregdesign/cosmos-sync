import 'package:flutter/material.dart';

class OwnerAuthGate extends StatefulWidget {
  const OwnerAuthGate({super.key, required this.onStart});

  final VoidCallback onStart;

  @override
  State<OwnerAuthGate> createState() => _OwnerAuthGateState();
}

class _OwnerAuthGateState extends State<OwnerAuthGate>
    with WidgetsBindingObserver {
  AppLifecycleState? _lifecycle;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = WidgetsBinding.instance.lifecycleState;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() => _lifecycle = state);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _start() {
    if (_started || _lifecycle != AppLifecycleState.resumed) {
      return;
    }
    setState(() => _started = true);
    widget.onStart();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Microsoft sign-in validation\n'
                  'Start here while Cosmos Sync is in the foreground.\n'
                  'Choose the approved workforce provider in the browser.\n'
                  'Credentials stay with Microsoft; no token is shown here.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  key: const ValueKey('owner_auth_start'),
                  onPressed:
                      !_started && _lifecycle == AppLifecycleState.resumed
                      ? _start
                      : null,
                  child: Text(
                    _started ? 'Sign-in started' : 'Start Microsoft sign-in',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
