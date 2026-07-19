import Flutter
import Foundation

/// Native-side logging entry point. Call from any Swift/Obj-C class in the
/// app, e.g.:
/// ```swift
/// LogKitNative.d(tag: "Auth", message: "token refreshed")
/// LogKitNative.e(tag: "Push", message: "failed to register token", error: "\(error)")
/// ```
///
/// Forwards to Dart's `LogKit` (retention, formatting, redaction, dump/share
/// all stay implemented once, in Dart — see `NativeLogBridge` on the Dart
/// side) over the `log_kit` `FlutterMethodChannel` that `LogKitPlugin`
/// registers.
///
/// This type is process-wide (not per-engine): with more than one
/// `FlutterEngine` alive (add-to-app / `FlutterEngineGroup`), it always
/// targets whichever engine attached most recently. `detachIf` guards
/// against an older engine's teardown clobbering a newer engine's
/// channel.
///
/// A call made before a `FlutterEngine` is attached (e.g. from
/// `application(_:didFinishLaunchingWithOptions:)` before the Flutter view
/// controller is created) or after the active engine detaches is silently
/// dropped — there is no Dart isolate listening yet/anymore. This mirrors
/// `LogKit.init()`'s own pre-init drop behavior on the Dart side.
public enum LogKitNative {
  private static var channel: FlutterMethodChannel?

  static func attach(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  /// Clears the channel only if it is still `expected` — i.e. only if no
  /// other `LogKitPlugin` instance has attached (and overwritten it)
  /// since this one attached. Called from `detachFromEngine(for:)`.
  static func detachIf(channel expected: FlutterMethodChannel?) {
    if channel === expected {
      channel = nil
    }
  }

  public static func v(tag: String, message: String, error: String? = nil) {
    log(level: "verbose", tag: tag, message: message, error: error)
  }

  public static func d(tag: String, message: String, error: String? = nil) {
    log(level: "debug", tag: tag, message: message, error: error)
  }

  public static func i(tag: String, message: String, error: String? = nil) {
    log(level: "info", tag: tag, message: message, error: error)
  }

  public static func w(tag: String, message: String, error: String? = nil) {
    log(level: "warn", tag: tag, message: message, error: error)
  }

  public static func e(tag: String, message: String, error: String? = nil) {
    log(level: "error", tag: tag, message: message, error: error)
  }

  private static func log(level: String, tag: String, message: String, error: String?) {
    let args: [String: Any?] = [
      "level": level,
      "tag": tag,
      "message": message,
      "error": error,
      "platform": "ios",
      "timestampMillis": Int(Date().timeIntervalSince1970 * 1000),
    ]
    // FlutterMethodChannel calls must be made on the main thread.
    if Thread.isMainThread {
      channel?.invokeMethod("log", arguments: args)
    } else {
      DispatchQueue.main.async {
        channel?.invokeMethod("log", arguments: args)
      }
    }
  }
}
