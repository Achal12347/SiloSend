package com.achyrio.vayu.pairing

import android.app.Activity
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.IsoDep
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * NFC tap-to-pair bridge.
 *
 * Methods on `com.achyrio.vayu/nfc`: isAvailable, isEnabled, serve(bytes),
 * stopServing, startReading, stopReading. Payloads read from a peer arrive on
 * the event channel `com.achyrio.vayu/nfc_events` as raw bytes.
 */
class NfcHandler(private val activity: Activity) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        private const val TAG = "Vayu.Nfc"
        private const val METHOD = "com.achyrio.vayu/nfc"
        private const val EVENTS = "com.achyrio.vayu/nfc_events"
        private const val READ_CHUNK = 240
        private const val MAX_PAYLOAD = 8 * 1024
    }

    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var sink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())
    private val adapter: NfcAdapter? get() = NfcAdapter.getDefaultAdapter(activity)

    fun register(messenger: BinaryMessenger) {
        methods = MethodChannel(messenger, METHOD).also { it.setMethodCallHandler(this) }
        events = EventChannel(messenger, EVENTS).also { it.setStreamHandler(this) }
    }

    fun unregister() {
        stopReading()
        PairingHceService.payload = null
        methods?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        methods = null
        events = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(adapter != null)
            "isEnabled" -> result.success(adapter?.isEnabled == true)
            "serve" -> {
                PairingHceService.payload = call.argument<ByteArray>("bytes")
                result.success(true)
            }
            "stopServing" -> {
                PairingHceService.payload = null
                result.success(true)
            }
            "startReading" -> {
                val nfc = adapter
                if (nfc == null || !nfc.isEnabled) {
                    result.error("UNAVAILABLE", "NFC is off or missing", null)
                    return
                }
                nfc.enableReaderMode(
                    activity,
                    { tag -> readPeer(tag) },
                    NfcAdapter.FLAG_READER_NFC_A or NfcAdapter.FLAG_READER_NFC_B or
                        NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK,
                    null,
                )
                result.success(true)
            }
            "stopReading" -> {
                stopReading()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun stopReading() {
        try {
            adapter?.disableReaderMode(activity)
        } catch (_: Exception) {}
    }

    // Runs on the NFC binder thread; the tap lasts long enough for a few APDUs.
    private fun readPeer(tag: Tag) {
        val iso = IsoDep.get(tag) ?: return
        try {
            iso.connect()
            iso.timeout = 3000
            val select = byteArrayOf(0x00, 0xA4.toByte(), 0x04, 0x00, PairingHceService.AID.size.toByte()) +
                PairingHceService.AID + byteArrayOf(0x00)
            if (!ok(iso.transceive(select))) return
            val lengthReply = iso.transceive(byteArrayOf(0x80.toByte(), 0xCA.toByte(), 0x00, 0x00, 0x02))
            if (!ok(lengthReply) || lengthReply.size < 4) return
            val length = ((lengthReply[0].toInt() and 0xFF) shl 8) or (lengthReply[1].toInt() and 0xFF)
            if (length <= 0 || length > MAX_PAYLOAD) return
            val out = ByteArrayOutputStream()
            var offset = 0
            while (offset < length) {
                val reply = iso.transceive(
                    byteArrayOf(0x00, 0xB0.toByte(), (offset shr 8).toByte(), offset.toByte(), READ_CHUNK.toByte()),
                )
                if (!ok(reply) || reply.size <= 2) break
                out.write(reply, 0, reply.size - 2)
                offset += reply.size - 2
            }
            if (out.size() == length) {
                val bytes = out.toByteArray()
                main.post { sink?.success(bytes) }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Peer read failed: ${e.javaClass.simpleName}")
        } finally {
            try {
                iso.close()
            } catch (_: Exception) {}
        }
    }

    private fun ok(reply: ByteArray) =
        reply.size >= 2 && reply[reply.size - 2] == 0x90.toByte() && reply[reply.size - 1] == 0x00.toByte()
}
