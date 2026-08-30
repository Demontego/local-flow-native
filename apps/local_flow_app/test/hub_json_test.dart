import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

/// Pure JSON shape checks for Hub snapshot / personalization (no native lib).
void main() {
  test('hub snapshot shape parses stats sessions notes', () {
    const raw = '''
{
  "stats": {
    "words_today": 12,
    "words_week": 40,
    "streak_days": 3,
    "sessions_today": 2,
    "last_preview": "привет"
  },
  "sessions": [
    {"preview": "привет мир", "mode": "field", "word_count": 2}
  ],
  "notes": [
    {"id": "1", "text": "scratch"}
  ]
}
''';
    final snap = jsonDecode(raw) as Map<String, dynamic>;
    expect(snap['stats']['words_today'], 12);
    expect((snap['sessions'] as List).length, 1);
    expect((snap['notes'] as List).first['text'], 'scratch');
  });

  test('personalization dictionary roundtrip encodes for save', () {
    final personal = <String, dynamic>{
      'dictionary': [
        {'heard': 'кубинетес', 'replace_with': 'Kubernetes'},
      ],
      'snippets': <Map<String, String>>[],
      'app_styles': <String, String>{},
      'cleanup_enabled': true,
    };
    final encoded = jsonEncode(personal);
    final decoded = jsonDecode(encoded) as Map<String, dynamic>;
    expect(decoded['cleanup_enabled'], isTrue);
    expect(
      (decoded['dictionary'] as List).first['replace_with'],
      'Kubernetes',
    );
  });
}
