import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:log_vault/log_vault.dart';

/// Simulates a native (Kotlin/Swift) `LogVaultNative` call arriving over the
/// `log_vault` MethodChannel, the same way the platform engine would deliver
/// it to a real app's Dart isolate.
Future<void> _simulateNativeLogCall(Map<Object?, Object?> arguments) async {
  final byteData = const StandardMethodCodec().encodeMethodCall(
    MethodCall('log', arguments),
  );
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage('log_vault', byteData, (_) {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('forwards a native log call into onEntry as a LogEntry', () async {
    final received = <LogEntry>[];
    final bridge = NativeLogBridge(onEntry: received.add);
    bridge.attach();

    await _simulateNativeLogCall({
      'level': 'warn',
      'tag': 'Auth',
      'message': 'token refresh failed',
      'error': 'HttpException: 401',
      'platform': 'android',
      'timestampMillis': 1767225600000, // 2026-01-01T00:00:00Z
    });

    expect(received, hasLength(1));
    final entry = received.single;
    expect(entry.level, LogLevel.warn);
    expect(entry.tag, 'Auth');
    expect(entry.message, 'token refresh failed');
    expect(entry.error, 'HttpException: 401');
    expect(entry.context['platform'], 'android');
    expect(
      entry.timestamp,
      DateTime.fromMillisecondsSinceEpoch(1767225600000),
    );

    await bridge.detach();
  });

  test('falls back to LogLevel.info for an unrecognized level string', () async {
    final received = <LogEntry>[];
    final bridge = NativeLogBridge(onEntry: received.add);
    bridge.attach();

    await _simulateNativeLogCall({
      'level': 'not-a-real-level',
      'tag': 'X',
      'message': 'm',
    });

    expect(received.single.level, LogLevel.info);

    await bridge.detach();
  });

  test('ignores method calls other than "log"', () async {
    final received = <LogEntry>[];
    final bridge = NativeLogBridge(onEntry: received.add);
    bridge.attach();

    final byteData = const StandardMethodCodec().encodeMethodCall(
      const MethodCall('somethingElse', {}),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage('log_vault', byteData, (_) {});

    expect(received, isEmpty);

    await bridge.detach();
  });

  test('LogVault.init() with enableNativeBridge: false does not register a handler', () async {
    await LogVault.init(
      LogVaultConfig(
        appName: 'testapp',
        directory: (await Directory.systemTemp.createTemp('log_vault_')).path,
        enableNativeBridge: false,
      ),
    );

    // With no handler registered, a simulated native call must not throw
    // and must not appear in recentEntries.
    await _simulateNativeLogCall({
      'level': 'error',
      'tag': 'X',
      'message': 'should be ignored',
    });

    expect(
      LogVault.recentEntries.where((e) => e.message == 'should be ignored'),
      isEmpty,
    );

    await LogVault.resetForTesting();
  });
}
