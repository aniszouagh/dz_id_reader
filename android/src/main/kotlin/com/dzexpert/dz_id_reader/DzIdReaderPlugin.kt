package com.dzexpert.dz_id_reader

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.TagLostException
import android.nfc.tech.IsoDep
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * The NFC part of dz_id_reader: waits for a smart card (ISO-DEP) in reader
 * mode and passes raw commands to it. Secure messaging and everything above
 * it is done in Dart.
 */
class DzIdReaderPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    NfcAdapter.ReaderCallback {

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activity: Activity? = null
    private val main = Handler(Looper.getMainLooper())

    // One thread for connecting and for commands, so they never overlap.
    private val io = Executors.newSingleThreadExecutor()

    // Main thread only.
    private var holding = false
    private var readerOn = false
    private var pending: MethodChannel.Result? = null
    private var pendingTimeout: Runnable? = null
    private var card: IsoDep? = null

    // Read on the io thread too.
    @Volatile private var waiting = false
    @Volatile private var commandTimeoutMs = 5000

    // A card Android found while no read was waiting, or the card of the
    // last read. The next connect tries it first, so a card that is already
    // on the phone is used at once.
    @Volatile private var lastTag: Tag? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "dz_id_reader")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        io.shutdown()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        updateReaderMode()
    }

    override fun onDetachedFromActivityForConfigChanges() = detach()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() = detach()

    private fun detach() {
        finishPending { it.error("cancelled", "The screen went away", null) }
        activity?.let { a ->
            if (readerOn) {
                try {
                    NfcAdapter.getDefaultAdapter(a)?.disableReaderMode(a)
                } catch (e: Exception) {
                    Log.w(TAG, "Could not stop reader mode", e)
                }
            }
        }
        readerOn = false
        activity = null
    }

    private fun adapter(): NfcAdapter? = NfcAdapter.getDefaultAdapter(activity ?: context)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "state" -> {
                val adapter = adapter()
                result.success(
                    when {
                        adapter == null -> "notSupported"
                        !adapter.isEnabled -> "off"
                        else -> "on"
                    }
                )
            }
            "openSettings" -> openSettings(result)
            "hold" -> {
                holding = call.arguments as Boolean
                updateReaderMode()
                result.success(null)
            }
            "connect" -> connect(call, result)
            "transceive" -> transceive(call.arguments as ByteArray, result)
            "close" -> close(result)
            "cancel" -> {
                finishPending { it.error("cancelled", null, null) }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun openSettings(result: MethodChannel.Result) {
        val a = activity ?: return result.error("noActivity", null, null)
        try {
            a.startActivity(Intent(Settings.ACTION_NFC_SETTINGS))
        } catch (e: Exception) {
            a.startActivity(Intent(Settings.ACTION_WIRELESS_SETTINGS))
        }
        result.success(null)
    }

    private fun connect(call: MethodCall, result: MethodChannel.Result) {
        val adapter = adapter() ?: return result.error("notSupported", null, null)
        if (!adapter.isEnabled) return result.error("off", null, null)
        if (activity == null) return result.error("noActivity", null, null)
        // A connect replaces whatever an earlier one left behind (after a
        // hot restart of the Dart side, for example).
        finishPending { it.error("cancelled", "Replaced by a new connect", null) }
        card?.let { stale ->
            card = null
            io.execute { closeQuietly(stale) }
        }
        commandTimeoutMs = call.argument<Int>("commandTimeoutMs") ?: 5000
        val timeout = Runnable { finishPending { it.error("timeout", null, null) } }
        pending = result
        pendingTimeout = timeout
        waiting = true
        main.postDelayed(timeout, (call.argument<Int>("timeoutMs") ?: 30000).toLong())
        updateReaderMode()
        lastTag?.let { tag -> io.execute { connectTo(tag, repollOnFailure = true) } }
    }

    override fun onTagDiscovered(tag: Tag) {
        lastTag = tag
        io.execute { connectTo(tag, repollOnFailure = false) }
    }

    // On the io thread.
    private fun connectTo(tag: Tag, repollOnFailure: Boolean) {
        if (!waiting) return
        val dep = IsoDep.get(tag) ?: return // not a smart card: keep waiting
        try {
            dep.connect()
            dep.timeout = commandTimeoutMs
        } catch (e: Exception) {
            // Gone already. Wait for Android to find a card; a fresh poll
            // also finds one that is still lying on the phone.
            if (lastTag === tag) lastTag = null
            closeQuietly(dep)
            if (repollOnFailure) main.post { repoll() }
            return
        }
        waiting = false
        main.post {
            val r = pending
            pending = null
            pendingTimeout?.let { main.removeCallbacks(it) }
            pendingTimeout = null
            if (r == null) { // cancelled or timed out meanwhile
                io.execute { closeQuietly(dep) }
                updateReaderMode()
                return@post
            }
            card = dep
            r.success(
                mapOf(
                    "extendedLength" to dep.isExtendedLengthApduSupported,
                    "maxTransceive" to dep.maxTransceiveLength,
                )
            )
        }
    }

    private fun transceive(command: ByteArray, result: MethodChannel.Result) {
        val dep = card ?: return result.error("notConnected", null, null)
        io.execute {
            try {
                val answer = dep.transceive(command)
                main.post { result.success(answer) }
            } catch (e: TagLostException) {
                main.post { result.error("tagLost", e.message, null) }
            } catch (e: Exception) {
                main.post { result.error("io", e.toString(), null) }
            }
        }
    }

    private fun close(result: MethodChannel.Result) {
        val dep = card
        card = null
        io.execute {
            if (dep != null) {
                lastTag = dep.tag
                closeQuietly(dep)
            }
            main.post {
                updateReaderMode()
                result.success(null)
            }
        }
    }

    private fun finishPending(reply: (MethodChannel.Result) -> Unit) {
        waiting = false
        pendingTimeout?.let { main.removeCallbacks(it) }
        pendingTimeout = null
        val r = pending
        pending = null
        if (r != null) reply(r)
        updateReaderMode()
    }

    // Reader mode is on while Dart holds NFC, waits for a card or talks to
    // one. Android pauses and restores it with the activity by itself.
    private fun updateReaderMode() {
        val a = activity ?: return
        val adapter = NfcAdapter.getDefaultAdapter(a) ?: return
        val wanted = holding || pending != null || card != null
        try {
            if (wanted && !readerOn) {
                val options = Bundle()
                // Fewer presence checks while a card sits on the phone between
                // commands; they can disturb slow chips.
                options.putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY, 1000)
                adapter.enableReaderMode(a, this, FLAGS, options)
                readerOn = true
            } else if (!wanted && readerOn) {
                adapter.disableReaderMode(a)
                readerOn = false
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not change reader mode", e)
        }
    }

    private fun repoll() {
        if (pending == null || !readerOn) return
        val a = activity ?: return
        try {
            NfcAdapter.getDefaultAdapter(a)?.disableReaderMode(a)
        } catch (e: Exception) {
            Log.w(TAG, "Could not restart polling", e)
        }
        readerOn = false
        updateReaderMode()
    }

    private fun closeQuietly(dep: IsoDep) {
        try {
            dep.close()
        } catch (e: Exception) {
            // already closed
        }
    }

    companion object {
        private const val TAG = "dz_id_reader"
        private const val FLAGS = NfcAdapter.FLAG_READER_NFC_A or
            NfcAdapter.FLAG_READER_NFC_B or
            NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK or
            NfcAdapter.FLAG_READER_NO_PLATFORM_SOUNDS
    }
}
