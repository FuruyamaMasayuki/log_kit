import 'package:flutter_test/flutter_test.dart';
import 'package:log_kit/log_kit.dart';

void main() {
  test(
    'maps every LogLevel to dart:developer\'s conventional severity scale',
    () {
      // Regression test: `severity * 200` used to map LogLevel.error to
      // 800 (dart:developer's INFO) and LogLevel.warn to 600 (between
      // CONFIG and FINE), silently breaking DevTools/IDE level filtering.
      expect(ConsoleSink.developerLevels, {
        LogLevel.verbose: 300, // FINEST
        LogLevel.debug: 500, // FINE
        LogLevel.info: 800, // INFO
        LogLevel.warn: 900, // WARNING
        LogLevel.error: 1000, // SEVERE
      });

      // Every LogLevel must have an explicit entry (no reliance on the
      // `?? 800` fallback in ConsoleSink.write for a real level value).
      for (final level in LogLevel.values) {
        expect(
          ConsoleSink.developerLevels.containsKey(level),
          isTrue,
          reason: '$level has no explicit dart:developer level mapping',
        );
      }

      // The old buggy `severity * 200` formula must disagree with the
      // fixed table for warn/error, proving this isn't a vacuous check.
      expect(LogLevel.warn.severity * 200, isNot(ConsoleSink.developerLevels[LogLevel.warn]));
      expect(LogLevel.error.severity * 200, isNot(ConsoleSink.developerLevels[LogLevel.error]));
    },
  );
}
