package com.flutterplugin.log_kit

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/**
 * Registers the `log_kit` MethodChannel against the running Flutter engine
 * so native (Kotlin/Java) app code can forward log lines to Dart's `LogKit`
 * via [LogKitNative] without holding its own reference to the channel or
 * `BinaryMessenger`.
 *
 * Each [LogKitPlugin] instance is tied to one [FlutterEngine][io.flutter.embedding.engine.FlutterEngine]
 * (add-to-app / `FlutterEngineGroup` setups can run several engines, each
 * with its own plugin instance). [onDetachedFromEngine] only clears
 * [LogKitNative]'s channel if it still points at *this* instance's
 * channel — otherwise, engine A detaching after engine B has attached
 * would silently kill engine B's still-live logging.
 */
class LogKitPlugin : FlutterPlugin {
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val newChannel = MethodChannel(binding.binaryMessenger, "log_kit")
        channel = newChannel
        LogKitNative.attach(newChannel)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        LogKitNative.detachIf(channel)
        channel = null
    }
}
