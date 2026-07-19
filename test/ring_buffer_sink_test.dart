import 'package:flutter_test/flutter_test.dart';
import 'package:log_vault/log_vault.dart';

LogEntry _entry(String message) => LogEntry(
  timestamp: DateTime(2026, 1, 1),
  level: LogLevel.debug,
  message: message,
);

void main() {
  group('RingBufferSink', () {
    test('keeps only the most recent `capacity` entries', () {
      final sink = RingBufferSink(3);
      for (var i = 0; i < 5; i++) {
        sink.write(_entry('msg $i'));
      }
      expect(sink.entries.map((e) => e.message), ['msg 2', 'msg 3', 'msg 4']);
    });

    test('capacity 0 keeps nothing', () {
      final sink = RingBufferSink(0);
      sink.write(_entry('msg'));
      expect(sink.entries, isEmpty);
    });

    test('clear empties the buffer', () {
      final sink = RingBufferSink(3);
      sink.write(_entry('msg'));
      sink.clear();
      expect(sink.entries, isEmpty);
    });
  });

  group('LogLevel', () {
    test('compares by severity, not declaration order alone', () {
      expect(LogLevel.error > LogLevel.warn, isTrue);
      expect(LogLevel.verbose < LogLevel.debug, isTrue);
      expect(LogLevel.info >= LogLevel.info, isTrue);
      expect(LogLevel.warn <= LogLevel.error, isTrue);
    });
  });
}
