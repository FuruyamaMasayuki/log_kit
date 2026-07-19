import 'package:flutter/services.dart';

import 'log_entry.dart';
import 'log_level.dart';

/// Receives log calls made by native (Kotlin/Swift) app code via the
/// `log_kit` `MethodChannel` and turns them into [LogEntry]s for [onEntry]
/// to dispatch to `LogKit`'s sinks.
///
/// Native app code calls `LogKitNative.d(tag, message)` (Android) or
/// `LogKitNative.d(tag: tag, message: message)` (iOS), which invokes this
/// channel's `'log'` method with the entry's fields. See the platform
/// plugin sources under `android/` and `ios/`.
///
/// A native call can only reach Dart while a `FlutterEngine` is attached
/// and this isolate's channel handler is registered (i.e. after
/// `LogKit.init()` has run). Calls made from native code before that —
/// e.g. from an `Application.onCreate()` that runs before Flutter starts —
/// are silently dropped on the native side; there is no Dart isolate to
/// receive them.
class NativeLogBridge {
  NativeLogBridge({
    MethodChannel channel = const MethodChannel('log_kit'),
    required this.onEntry,
  }) : _channel = channel;

  final MethodChannel _channel;
  final void Function(LogEntry entry) onEntry;

  void attach() => _channel.setMethodCallHandler(_handle);

  Future<void> detach() async => _channel.setMethodCallHandler(null);

  Future<void> _handle(MethodCall call) async {
    if (call.method != 'log') return;
    final args = Map<Object?, Object?>.from(call.arguments as Map);

    final timestampMillis = args['timestampMillis'] as int?;
    onEntry(
      LogEntry(
        timestamp: timestampMillis != null
            ? DateTime.fromMillisecondsSinceEpoch(timestampMillis)
            : DateTime.now(),
        level: _parseLevel(args['level'] as String?),
        message: args['message'] as String? ?? '',
        tag: args['tag'] as String?,
        error: args['error'] as String?,
        context: {
          'platform': args['platform'] as String? ?? 'native',
        },
      ),
    );
  }

  static LogLevel _parseLevel(String? raw) {
    for (final level in LogLevel.values) {
      if (level.name == raw) return level;
    }
    return LogLevel.info;
  }
}
