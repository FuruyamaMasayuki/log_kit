import Flutter
import UIKit

/// Registers the `log_kit` `FlutterMethodChannel` against the running
/// Flutter engine so native (Swift/Obj-C) app code can forward log lines
/// to Dart's `LogKit` via `LogKitNative`, without holding its own
/// reference to the channel or `FlutterBinaryMessenger`.
///
/// Publishes itself to the engine's plugin registry via
/// `registrar.publish(_:)` so the engine invokes `detachFromEngine(for:)`
/// on teardown. Per FlutterPlugin.h, that callback is ONLY delivered to
/// instances registered through `publish:` — `addMethodCallDelegate`
/// alone does not opt in to it. Without the detach callback, an
/// add-to-app / `FlutterEngineGroup` setup with multiple engines would
/// have no way to tell `LogKitNative` "this specific engine is gone"
/// without risking clobbering a different, still-live engine.
public class LogKitPlugin: NSObject, FlutterPlugin {
  private var channel: FlutterMethodChannel?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = LogKitPlugin()
    let channel = FlutterMethodChannel(
      name: "log_kit",
      binaryMessenger: registrar.messenger()
    )
    instance.channel = channel
    // Retains the instance for the engine's lifetime AND opts it in to
    // detachFromEngine(for:) — see the class doc comment. This channel is
    // native -> Dart only (Dart never calls back into native on it), so
    // no addMethodCallDelegate/handle() is needed.
    registrar.publish(instance)
    LogKitNative.attach(channel: channel)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    LogKitNative.detachIf(channel: channel)
    channel = nil
  }
}
