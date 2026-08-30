import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'native_engine.dart';

class LocalFlowApp extends StatelessWidget {
  const LocalFlowApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: Colors.teal);
    return MaterialApp(
      title: 'Local Flow',
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        // Flat, tonal, rounded cards — a quiet modern surface.
        cardTheme: CardThemeData(
          elevation: 0,
          color: scheme.surfaceContainerHighest,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
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
        _status = 'Tap Get started to download and load the models.';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _status = 'Native engine unavailable: $error');
      }
    }
  }

  /// One tap: download Whisper + Gemma (if missing) and load them.
  /// Collapses the former three separate buttons into a single flow.
  Future<void> _getStarted() async {
    final engine = _engine;
    if (engine == null || _busy) {
      return;
    }
    final steps = <MapEntry<String, String Function()>>[
      MapEntry('Downloading Whisper', engine.downloadWhisper),
      MapEntry('Downloading Gemma 4', engine.downloadQwen),
      MapEntry('Loading models', engine.loadModels),
    ];
    setState(() {
      _busy = true;
      _status = 'Setting up…';
    });
    try {
      for (final step in steps) {
        if (mounted) {
          setState(() => _status = '${step.key}…');
        }
        final result = await Future<String>.sync(step.value);
        if (result.startsWith('error:')) {
          throw StateError(result);
        }
      }
      await _platform.invokeMethod<void>('setModelsReady', true);
      if (mounted) {
        setState(() => _status = 'Ready. Hold to talk in the keyboard.');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _status = 'Setup failed: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
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
    final ready = _engine != null;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Local Flow')),
      // Constrain to a comfortable reading column and centre it — clean on
      // phones and on wide tablet/desktop windows alike.
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
            children: [
              Text(
                'On-device dictation',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Hold to talk, review Whisper partials, insert one Gemma-cleaned result. '
                'Audio, models, history, and personalization stay on this device.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              _StatusCard(status: _status, busy: _busy),
              const SizedBox(height: 16),
              const _HowItWorks(),
              const SizedBox(height: 24),
              Tooltip(
                message:
                    'Downloads Whisper + Gemma 4 (~3.3 GB) once, then loads them. '
                    'Everything runs on-device.',
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _busy || !ready ? null : _getStarted,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                    icon: const Icon(Icons.download_done),
                    label: const Text('Get started'),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'One tap downloads and loads both models. First run needs Wi-Fi and a few minutes.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              _KeyboardStep(
                enabled: _imeEnabled,
                onOpenSettings: _openInputSettings,
              ),
              const SizedBox(height: 8),
              _AdvancedSection(
                busy: _busy,
                ready: ready,
                onDownloadWhisper: () => _run(
                    'Downloading Whisper', (engine) => engine.downloadWhisper()),
                onDownloadGemma: () => _run(
                    'Downloading Gemma 4', (engine) => engine.downloadQwen()),
                onLoadModels: () =>
                    _run('Loading models', (engine) => engine.loadModels()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Three-step "what do I do" hint card — the primary onboarding aid.
class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context) {
    const steps = [
      (Icons.download_done, 'Tap Get started', 'Downloads and loads the models once.'),
      (Icons.keyboard, 'Enable the keyboard', 'Turn on the Local Flow keyboard in system settings.'),
      (Icons.mic, 'Hold to talk', 'Hold the mic key, speak, release — cleaned text is inserted.'),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'How it works',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            for (var i = 0; i < steps.length; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 14,
                    child: Text('${i + 1}'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          steps[i].$2,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        Text(
                          steps[i].$3,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  Icon(steps[i].$1, color: Theme.of(context).colorScheme.primary),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The one remaining required action after setup: enable the system keyboard.
class _KeyboardStep extends StatelessWidget {
  const _KeyboardStep({required this.enabled, required this.onOpenSettings});

  final bool enabled;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(
          enabled ? Icons.check_circle : Icons.keyboard,
          color: enabled ? Colors.green : null,
        ),
        title: Text(
          Platform.isAndroid ? 'Android keyboard' : 'iOS keyboard extension',
        ),
        subtitle: Text(
          enabled
              ? 'Enabled — hold the mic key to dictate.'
              : 'Enable it in system settings to start dictating.',
        ),
        trailing: enabled
            ? null
            : FilledButton.tonal(
                onPressed: onOpenSettings,
                child: const Text('Open settings'),
              ),
      ),
    );
  }
}

/// Power-user controls, collapsed by default to keep the main screen minimal.
class _AdvancedSection extends StatelessWidget {
  const _AdvancedSection({
    required this.busy,
    required this.ready,
    required this.onDownloadWhisper,
    required this.onDownloadGemma,
    required this.onLoadModels,
  });

  final bool busy;
  final bool ready;
  final VoidCallback onDownloadWhisper;
  final VoidCallback onDownloadGemma;
  final VoidCallback onLoadModels;

  @override
  Widget build(BuildContext context) {
    final enabled = ready && !busy;
    return ExpansionTile(
      title: const Text('Advanced'),
      childrenPadding: const EdgeInsets.only(bottom: 8),
      children: [
        OutlinedButton(
          onPressed: enabled ? onDownloadWhisper : null,
          child: const Text('Download Whisper only'),
        ),
        OutlinedButton(
          onPressed: enabled ? onDownloadGemma : null,
          child: const Text('Download Gemma 4 only'),
        ),
        OutlinedButton(
          onPressed: enabled ? onLoadModels : null,
          child: const Text('Reload models'),
        ),
        const ListTile(
          dense: true,
          title: Text('Recovery'),
          subtitle: Text(
            'If a model fails to load, delete downloaded models and run Get started again. '
            'Microphone is requested only while dictating; the local keyboard needs no Full Access.',
          ),
        ),
      ],
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
