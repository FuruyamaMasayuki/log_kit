package com.flutterplugin.log_vault

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/**
 * Registers the `log_vault` MethodChannel against the running Flutter engine
 * so native (Kotlin/Java) app code can forward log lines to Dart's `LogVault`
 * via [LogVaultNative] without holding its own reference to the channel or
 * `BinaryMessenger`.
 *
 * Each [LogVaultPlugin] instance is tied to one [FlutterEngine][io.flutter.embedding.engine.FlutterEngine]
 * (add-to-app / `FlutterEngineGroup` setups can run several engines, each
 * with its own plugin instance). [onDetachedFromEngine] only clears
 * [LogVaultNative]'s channel if it still points at *this* instance's
 * channel — otherwise, engine A detaching after engine B has attached
 * would silently kill engine B's still-live logging.
 */
class LogVaultPlugin : FlutterPlugin {
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val newChannel = MethodChannel(binding.binaryMessenger, "log_vault")
        channel = newChannel
        LogVaultNative.attach(newChannel)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        LogVaultNative.detachIf(channel)
        channel = null
    }
}
