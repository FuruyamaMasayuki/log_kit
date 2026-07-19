import 'package:flutter_test/flutter_test.dart';
import 'package:log_vault/log_vault.dart';

void main() {
  test('formats level, tag, message and context', () {
    const formatter = LogFormatter();
    final entry = LogEntry(
      timestamp: DateTime(2026, 1, 1, 12, 0, 0),
      level: LogLevel.warn,
      message: 'token refresh failed',
      tag: 'Auth',
      context: {'flowId': 'abc123'},
    );

    final line = formatter.format(entry);
    expect(line, contains('W'));
    expect(line, contains('[Auth]'));
    expect(line, contains('token refresh failed'));
    expect(line, contains('flowId=abc123'));
  });

  test('applies redaction rules over the fully formatted line', () {
    final formatter = LogFormatter(
      redactionRules: [
        RedactionRule(RegExp(r'Bearer [A-Za-z0-9._-]+'), replacement: 'Bearer ***'),
      ],
    );
    final entry = LogEntry(
      timestamp: DateTime(2026, 1, 1),
      level: LogLevel.debug,
      message: 'Authorization: Bearer secret.token.value',
    );

    expect(formatter.format(entry), isNot(contains('secret.token.value')));
    expect(formatter.format(entry), contains('Bearer ***'));
  });

  test('appends error and stack trace on their own lines', () {
    const formatter = LogFormatter();
    final entry = LogEntry(
      timestamp: DateTime(2026, 1, 1),
      level: LogLevel.error,
      message: 'boom',
      error: StateError('bad state'),
      stackTrace: StackTrace.empty,
    );

    final line = formatter.format(entry);
    expect(line, contains('boom'));
    expect(line, contains('Bad state: bad state'));
  });
}
