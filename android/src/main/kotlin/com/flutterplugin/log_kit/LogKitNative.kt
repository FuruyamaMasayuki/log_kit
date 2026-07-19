package com.flutterplugin.log_kit

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/**
 * Native-side logging entry point. Call from any Kotlin/Java class in the
 * app, e.g.:
 * ```kotlin
 * LogKitNative.d("Auth", "token refreshed")
 * LogKitNative.e("Push", "failed to register token", error = e.toString())
 * ```
 *
 * Forwards to Dart's `LogKit` (retention, formatting, redaction, dump/share
 * all stay implemented once, in Dart — see `NativeLogBridge` on the Dart
 * side) over the `log_kit` MethodChannel that [LogKitPlugin] registers.
 *
 * This object is process-wide (not per-engine): with more than one
 * `FlutterEngine` alive (add-to-app / `FlutterEngineGroup`), it always
 * targets whichever engine attached most recently. [detachIf] guards
 * against an older engine's teardown clobbering a newer engine's channel.
 *
 * A call made before a `FlutterEngine` is attached (e.g. from
 * `Application.onCreate()` before Flutter starts) or after the active
 * engine detaches is silently dropped — there is no Dart isolate
 * listening yet/anymore. This mirrors `LogKit.init()`'s own pre-init drop
 * behavior on the Dart side.
 */
object LogKitNative {
    // @Volatile so a write from attach()/detachIf() (synchronized, possibly
    // on a different thread) is visible to the unsynchronized read in log()
    // below. Without it, a background-thread log() could see a stale channel
    // reference across the JMM memory boundary.
    @Volatile
    private var channel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    @Synchronized
    internal fun attach(newChannel: MethodChannel) {
        channel = newChannel
    }

    /**
     * Clears the channel only if it is still [expected] — i.e. only if no
     * other [LogKitPlugin] instance has attached (and overwritten it)
     * since this one attached. Called from `onDetachedFromEngine`.
     */
    @Synchronized
    internal fun detachIf(expected: MethodChannel?) {
        if (channel === expected) {
            channel = null
        }
    }

    @JvmStatic
    @JvmOverloads
    fun v(tag: String, message: String, error: String? = null) = log("verbose", tag, message, error)

    @JvmStatic
    @JvmOverloads
    fun d(tag: String, message: String, error: String? = null) = log("debug", tag, message, error)

    @JvmStatic
    @JvmOverloads
    fun i(tag: String, message: String, error: String? = null) = log("info", tag, message, error)

    @JvmStatic
    @JvmOverloads
    fun w(tag: String, message: String, error: String? = null) = log("warn", tag, message, error)

    @JvmStatic
    @JvmOverloads
    fun e(tag: String, message: String, error: String? = null) = log("error", tag, message, error)

    private fun log(level: String, tag: String, message: String, error: String?) {
        val args = mapOf(
            "level" to level,
            "tag" to tag,
            "message" to message,
            "error" to error,
            "platform" to "android",
            "timestampMillis" to System.currentTimeMillis(),
        )
        // MethodChannel calls must be made on the platform (main) thread.
        if (Looper.myLooper() == Looper.getMainLooper()) {
            channel?.invokeMethod("log", args)
        } else {
            mainHandler.post { channel?.invokeMethod("log", args) }
        }
    }
}
