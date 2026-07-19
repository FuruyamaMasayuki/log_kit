import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:log_kit/log_kit.dart';

/// Regression test for a real production crash: `LogKit.init()` used to
/// propagate the `MissingPluginException`/binding assertion thrown by
/// `getApplicationSupportDirectory()` and `MethodChannel.setMethodCallHandler`
/// when called from an isolate with no Flutter binding (a bare
/// `Isolate.spawn`/`Isolate.run`, as opposed to a Flutter-managed background
/// isolate like a workmanager or FCM background handler). `main()` awaiting
/// `LogKit.init()` would then crash app startup.
void main() {
  test(
    'init() does not throw in an isolate with no Flutter binding',
    () async {
      final error = await Isolate.run<String?>(() async {
        try {
          await LogKit.init(const LogKitConfig(appName: 'isolate-test'));
          // A second call must also stay non-throwing (it hits the
          // idempotency no-op path, not the degraded-init path).
          await LogKit.init(const LogKitConfig(appName: 'isolate-test-2'));
          // Logging, dumping, and sharing must all degrade gracefully
          // rather than throwing an *unexpected* exception type. dumpLogs()
          // is expected to throw StateError (file logging unavailable) —
          // anything else is the bug this test guards against.
          LogKit.d('should not throw even though file logging is down');
          try {
            await LogKit.dumpLogs();
            return 'dumpLogs() unexpectedly succeeded with no directory';
          } on StateError {
            // expected
          }
          return null;
        } catch (e) {
          return e.toString();
        }
      });

      expect(error, isNull);
    },
  );
}
