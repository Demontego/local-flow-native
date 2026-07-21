import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'native_engine.dart';

class LocalFlowApp extends StatelessWidget {
  const LocalFlowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Local Flow',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      home: const LocalFlowHome(),
    );
  }
}

class LocalFlowHome extends StatefulWidget {
  const LocalFlowHome({super.key});

  @override
  State<LocalFlowHome> createState() => _LocalFlowHomeState();
}

class _LocalFlowHomeState extends State<LocalFlowHome> {
  static const _platform = MethodChannel('ai.localflow/native');
  NativeEngine? _engine;
  String _status = 'Preparing Local Flow…';
  bool _busy = false;
  bool _imeEnabled = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final dataDirectory = await _platform.invokeMethod<String>(
        'applicationDataDirectory',
      );
      if (dataDirectory == null || dataDirectory.isEmpty) {
        throw StateError(
          'Platform did not provide an application data directory.',
        );
      }
      final engine = NativeEngine.open(dataDirectory);
      final imeEnabled = Platform.isAndroid
          ? await _platform.invokeMethod<bool>('isImeEnabled') ?? false
          : await _platform.invokeMethod<bool>('keyboardExtensionAvailable') ??
                false;
      if (!mounted) {
        engine.dispose();
        return;
      }
      setState(() {
        _engine = engine;
        _imeEnabled = imeEnabled;
        _status = 'Engine ready. Models are stored locally.';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _status = 'Native engine unavailable: $error');
      }
    }
  }

  Future<void> _run(
    String label,
    String Function(NativeEngine engine) action,
  ) async {
    final engine = _engine;
    if (engine == null || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _status = '$label…';
    });
    try {
      final result = await Future<String>.sync(() => action(engine));
      if (label.startsWith('Downloading') && !result.startsWith('error:')) {
        await _platform.invokeMethod<void>('setModelsReady', true);
      }
      if (mounted) {
        setState(() => _status = result);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _status = '$label failed: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _openInputSettings() async {
    await _platform.invokeMethod<void>('openInputSettings');
    final enabled = await _platform.invokeMethod<bool>('isImeEnabled') ?? false;
    if (mounted) {
      setState(() => _imeEnabled = enabled);
    }
  }

  @override
  void dispose() {
    _engine?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Local Flow')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'On-device dictation',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text(
            'Hold to talk in the keyboard, review Whisper partials, then insert one Qwen-cleaned result. '
            'Audio, models, history, and personalization stay on this device.',
          ),
          const SizedBox(height: 24),
          _StatusCard(status: _status, busy: _busy),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy
                ? null
                : () => _run('Loading models', (engine) => engine.loadModels()),
            child: const Text('Load downloaded models'),
          ),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _run(
                    'Downloading Whisper',
                    (engine) => engine.downloadWhisper(),
                  ),
            child: const Text('Download Whisper small'),
          ),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _run(
                    'Downloading Qwen3 1.7B Q4',
                    (engine) => engine.downloadQwen(),
                  ),
            child: const Text('Download Qwen3 1.7B Q4'),
          ),
          const Divider(height: 40),
          ListTile(
            title: Text(
              Platform.isAndroid
                  ? 'Android keyboard'
                  : 'iOS keyboard extension',
            ),
            subtitle: Text(
              _imeEnabled ? 'Available' : 'Enable it in system settings',
            ),
            trailing: FilledButton(
              onPressed: _openInputSettings,
              child: const Text('Open settings'),
            ),
          ),
          const ListTile(
            title: Text('Permissions'),
            subtitle: Text(
              'Microphone is requested only while dictating. Model downloads run in this host app; '
              'the local iOS keyboard does not require Full Access.',
            ),
          ),
          const ListTile(
            title: Text('Diagnostics'),
            subtitle: Text(
              'Use model load status above. Recovery: delete downloaded models and download again.',
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status, required this.busy});

  final String status;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            if (busy)
              const Padding(
                padding: EdgeInsets.only(right: 12),
                child: CircularProgressIndicator(),
              ),
            Expanded(child: Text(status)),
          ],
        ),
      ),
    );
  }
}
