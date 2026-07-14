import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no exception text is interpolated into a user-facing error', () {
    final offenders = <String>[];
    final leak = RegExp(r'''error:\s*['"][^'"]*\$(error|e)\b''');

    for (final file in Directory('lib/services/api').listSync()) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (leak.hasMatch(lines[i])) {
          offenders.add('${file.path}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'These would show a raw exception to the user. '
          'Return _failure(error, "what you were doing") instead:\n'
          '${offenders.join('\n')}',
    );
  });
}
