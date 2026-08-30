import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'native_engine.dart';

/// Local Hub: stats, history, scratch notes, dictionary — same data as IME.
class HubPage extends StatefulWidget {
  const HubPage({super.key, required this.engine});

  final NativeEngine engine;

  @override
  State<HubPage> createState() => _HubPageState();
}

class _HubPageState extends State<HubPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  Map<String, dynamic> _snap = {};
  Map<String, dynamic> _personal = {};
  String _status = '';
  bool _scratchArmed = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    _refresh();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _refresh() {
    setState(() {
      _snap = widget.engine.hubSnapshot();
      _personal = widget.engine.personalization();
      final stats = _snap['stats'] as Map? ?? {};
      _status =
          'Today ${stats['words_today'] ?? 0} · week ${stats['words_week'] ?? 0} · '
          'streak ${stats['streak_days'] ?? 0}d · sessions ${stats['sessions_today'] ?? 0}';
    });
  }

  List<Map<String, dynamic>> get _sessions {
    final raw = _snap['sessions'];
    if (raw is! List) {
      return const [];
    }
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  List<Map<String, dynamic>> get _notes {
    final raw = _snap['notes'];
    if (raw is! List) {
      return const [];
    }
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  List<Map<String, dynamic>> get _dictionary {
    final raw = _personal['dictionary'];
    if (raw is! List) {
      return const [];
    }
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<void> _addDictionaryRule() async {
    final heard = TextEditingController();
    final replace = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Dictionary rule'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: heard,
              decoration: const InputDecoration(
                labelText: 'Heard (ASR)',
                hintText: 'кубинетес',
              ),
              autofocus: true,
            ),
            TextField(
              controller: replace,
              decoration: const InputDecoration(
                labelText: 'Replace with',
                hintText: 'Kubernetes',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (ok != true) {
      return;
    }
    final h = heard.text.trim();
    final r = replace.text.trim();
    if (h.isEmpty || r.isEmpty) {
      return;
    }
    final next = Map<String, dynamic>.from(_personal);
    final dict = List<Map<String, dynamic>>.from(_dictionary)
      ..add({'heard': h, 'replace_with': r});
    next['dictionary'] = dict;
    final result = widget.engine.savePersonalizationJson(jsonEncode(next));
    if (!mounted) {
      return;
    }
    setState(() {
      _status = result == 'ok' ? 'Dictionary rule saved' : result;
    });
    _refresh();
  }

  Future<void> _removeDictionaryAt(int index) async {
    final dict = List<Map<String, dynamic>>.from(_dictionary);
    if (index < 0 || index >= dict.length) {
      return;
    }
    dict.removeAt(index);
    final next = Map<String, dynamic>.from(_personal);
    next['dictionary'] = dict;
    final result = widget.engine.savePersonalizationJson(jsonEncode(next));
    if (!mounted) {
      return;
    }
    setState(() {
      _status = result == 'ok' ? 'Rule removed' : result;
    });
    _refresh();
  }

  Future<void> _toggleCleanup(bool value) async {
    final next = Map<String, dynamic>.from(_personal);
    next['cleanup_enabled'] = value;
    final result = widget.engine.savePersonalizationJson(jsonEncode(next));
    if (!mounted) {
      return;
    }
    setState(() {
      _status = result == 'ok'
          ? (value ? 'Cleanup on' : 'Cleanup off')
          : result;
    });
    _refresh();
  }

  Future<void> _deleteNote(String id) async {
    final result = widget.engine.deleteScratchNote(id);
    if (!mounted) {
      return;
    }
    setState(() {
      _status = result == 'ok' ? 'Note deleted' : result;
    });
    _refresh();
  }

  Future<void> _learnFromEdit() async {
    final pasted = TextEditingController();
    final edited = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Learn from edit'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: pasted,
              decoration: const InputDecoration(labelText: 'Pasted text'),
              maxLines: 3,
            ),
            TextField(
              controller: edited,
              decoration: const InputDecoration(labelText: 'Edited text'),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Learn'),
          ),
        ],
      ),
    );
    if (ok != true) {
      return;
    }
    final result = widget.engine.learnFromEdit(
      pasted.text.trim(),
      edited.text.trim(),
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _status = result == '[]' ? 'No learnable edit' : 'Learned: $result';
    });
    _refresh();
  }

  void _armScratch() {
    widget.engine.setDestinationScratch(true);
    setState(() {
      _scratchArmed = true;
      _status =
          'Scratch mode on — switch to Local Flow keyboard and hold to talk.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final cleanup = _personal['cleanup_enabled'] != false;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Hub'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Home'),
            Tab(text: 'History'),
            Tab(text: 'Notes'),
            Tab(text: 'Dictionary'),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _status,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _HomeTab(
                  sessions: _sessions,
                  notesCount: _notes.length,
                  dictCount: _dictionary.length,
                  cleanupEnabled: cleanup,
                  scratchArmed: _scratchArmed,
                  onToggleCleanup: _toggleCleanup,
                  onScratch: _armScratch,
                  onLearn: _learnFromEdit,
                ),
                _HistoryTab(sessions: _sessions),
                _NotesTab(notes: _notes, onDelete: _deleteNote),
                _DictionaryTab(
                  rules: _dictionary,
                  onAdd: _addDictionaryRule,
                  onRemove: _removeDictionaryAt,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeTab extends StatelessWidget {
  const _HomeTab({
    required this.sessions,
    required this.notesCount,
    required this.dictCount,
    required this.cleanupEnabled,
    required this.scratchArmed,
    required this.onToggleCleanup,
    required this.onScratch,
    required this.onLearn,
  });

  final List<Map<String, dynamic>> sessions;
  final int notesCount;
  final int dictCount;
  final bool cleanupEnabled;
  final bool scratchArmed;
  final ValueChanged<bool> onToggleCleanup;
  final VoidCallback onScratch;
  final VoidCallback onLearn;

  @override
  Widget build(BuildContext context) {
    final last = sessions.isEmpty
        ? '—'
        : (sessions.first['preview'] as String? ?? '—');
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Local Flow Hub', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text('Last session: $last'),
        Text('Dictionary rules: $dictCount'),
        Text('Scratch notes: $notesCount'),
        Text('Sessions logged: ${sessions.length}'),
        const SizedBox(height: 16),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('LLM cleanup'),
          subtitle: const Text('Off = heuristic polish only'),
          value: cleanupEnabled,
          onChanged: onToggleCleanup,
        ),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          onPressed: onScratch,
          icon: Icon(scratchArmed ? Icons.check : Icons.note_add),
          label: Text(
            scratchArmed ? 'Scratch armed' : 'Dictate to Scratch',
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: onLearn,
          icon: const Icon(Icons.school_outlined),
          label: const Text('Learn from edit'),
        ),
        const SizedBox(height: 16),
        Text(
          'Tip: hold the Local Flow keyboard mic to dictate. '
          'History and dictionary stay on this device.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _HistoryTab extends StatelessWidget {
  const _HistoryTab({required this.sessions});

  final List<Map<String, dynamic>> sessions;

  @override
  Widget build(BuildContext context) {
    if (sessions.isEmpty) {
      return const Center(child: Text('No sessions yet'));
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: sessions.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final s = sessions[i];
        final preview = s['preview'] as String? ?? '';
        final mode = s['mode'] as String? ?? '';
        final words = s['word_count'] ?? '';
        return ListTile(
          title: Text(preview.isEmpty ? '(empty)' : preview),
          subtitle: Text('[$mode] ${words}w'),
          onTap: () {
            Clipboard.setData(ClipboardData(text: preview));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Copied')),
            );
          },
        );
      },
    );
  }
}

class _NotesTab extends StatelessWidget {
  const _NotesTab({required this.notes, required this.onDelete});

  final List<Map<String, dynamic>> notes;
  final ValueChanged<String> onDelete;

  @override
  Widget build(BuildContext context) {
    if (notes.isEmpty) {
      return const Center(child: Text('No scratch notes'));
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: notes.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final n = notes[i];
        final text = n['text'] as String? ?? '';
        final id = n['id'] as String? ?? '';
        return ListTile(
          title: Text(text),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: id.isEmpty ? null : () => onDelete(id),
          ),
          onTap: () {
            Clipboard.setData(ClipboardData(text: text));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Copied')),
            );
          },
        );
      },
    );
  }
}

class _DictionaryTab extends StatelessWidget {
  const _DictionaryTab({
    required this.rules,
    required this.onAdd,
    required this.onRemove,
  });

  final List<Map<String, dynamic>> rules;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add rule'),
            ),
          ),
        ),
        Expanded(
          child: rules.isEmpty
              ? const Center(child: Text('No dictionary rules'))
              : ListView.separated(
                  itemCount: rules.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final r = rules[i];
                    final heard = r['heard'] as String? ?? '';
                    final with_ = r['replace_with'] as String? ?? '';
                    return ListTile(
                      title: Text('$heard → $with_'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => onRemove(i),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
