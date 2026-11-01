package com.dzexpert.dz_id_reader

import android.app.Activity
import android.nfc.NfcAdapter
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class DzIdReaderPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private lateinit var channel: MethodChannel
    private var activity: Activity? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "dz_id_reader")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hold" -> {
                hold()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // While the app is open but not reading, keep reader mode on with a
    // callback that ignores every tag. Without it Android grabs the ID card
    // itself, fails to read it as an NDEF tag and shows a "cannot read NFC
    // tag" toast. flutter_nfc_kit's poll() replaces this callback when a
    // real read starts, so Dart calls hold after every read.
    private fun hold() {
        val activity = activity ?: return
        val adapter = NfcAdapter.getDefaultAdapter(activity) ?: return
        try {
            adapter.enableReaderMode(
                activity,
                { },
                NfcAdapter.FLAG_READER_NFC_A or
                    NfcAdapter.FLAG_READER_NFC_B or
                    NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK or
                    NfcAdapter.FLAG_READER_NO_PLATFORM_SOUNDS,
                null,
            )
        } catch (e: Exception) {
            Log.w("dz_id_reader", "Could not hold NFC reader mode", e)
        }
    }
}
