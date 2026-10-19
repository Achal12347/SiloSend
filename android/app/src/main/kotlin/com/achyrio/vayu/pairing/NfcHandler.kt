package com.achyrio.vayu.pairing

import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.nfc.NdefMessage
import android.nfc.NdefRecord
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.cardemulation.CardEmulation
import android.nfc.tech.IsoDep
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * NFC bridge for tap to pair, receive tickets and contact cards.
 *
 * Methods on `com.achyrio.vayu/nfc`: isAvailable, isEnabled, serve(bytes),
 * serveCard(bytes), stopServing, startReading, stopReading, takePendingCard.
 * Payloads read in reader mode arrive on `com.achyrio.vayu/nfc_events`.
 * Cards that Android's own tag reader delivered (Vayu opened by a tap) arrive
 * on `com.achyrio.vayu/nfc_cards`, or wait for `takePendingCard`.
 */
class NfcHandler(private val activity: Activity) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        private const val TAG = "Vayu.Nfc"
        private const val METHOD = "com.achyrio.vayu/nfc"
        private const val EVENTS = "com.achyrio.vayu/nfc_events"
        private const val CARD_EVENTS = "com.achyrio.vayu/nfc_cards"

        /** MIME type of a Vayu card in a standard NFC tag (lower case, as Android requires). */
        const val CARD_MIME = "application/vnd.achyrio.vayu.card"
        private const val READ_CHUNK = 240
        private const val MAX_PAYLOAD = 8 * 1024

        // Phones as cards answer presence checks slowly; the default (125 ms)
        // made the reader drop a phone mid-read.
        private const val PRESENCE_CHECK_MS = 1000

        // One tap is often read more than once while the phones touch.
        private const val SAME_TAP_MS = 2500L
    }

    // What Dart asked for. Android turns reader mode and the preferred card
    // service off whenever the activity pauses; these restore them on resume.
    private var readingWanted = false
    private var servingWanted = false
    private var lastRead: ByteArray? = null
    private var lastReadAt = 0L

    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var sink: EventChannel.EventSink? = null
    private var cardEvents: EventChannel? = null
    private var cardSink: EventChannel.EventSink? = null
    private var pendingCard: ByteArray? = null
    private val main = Handler(Looper.getMainLooper())
    private val adapter: NfcAdapter? get() = NfcAdapter.getDefaultAdapter(activity)

    fun register(messenger: BinaryMessenger) {
        methods = MethodChannel(messenger, METHOD).also { it.setMethodCallHandler(this) }
        events = EventChannel(messenger, EVENTS).also { it.setStreamHandler(this) }
        cardEvents = EventChannel(messenger, CARD_EVENTS).also {
            it.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    cardSink = events
                }

                override fun onCancel(arguments: Any?) {
                    cardSink = null
                }
            })
        }
    }

    /** Called from MainActivity for the launch intent and every new intent. */
    fun handleIntent(intent: Intent?) {
        if (intent?.action != NfcAdapter.ACTION_NDEF_DISCOVERED) return
        val card = extractCard(intent) ?: return
        // Consume it so a rotation or resume does not show the card twice.
        intent.action = Intent.ACTION_MAIN
        val live = cardSink
        if (live != null) {
            live.success(card)
        } else {
            pendingCard = card
        }
    }

    @Suppress("DEPRECATION")
    private fun extractCard(intent: Intent): ByteArray? {
        val raw = intent.getParcelableArrayExtra(NfcAdapter.EXTRA_NDEF_MESSAGES) ?: return null
        for (item in raw) {
            val message = item as? NdefMessage ?: continue
            for (record in message.records) {
                if (record.tnf == NdefRecord.TNF_MIME_MEDIA &&
                    String(record.type, Charsets.US_ASCII).lowercase() == CARD_MIME
                ) {
                    val payload = record.payload
                    if (payload.isNotEmpty() && payload.size <= MAX_PAYLOAD) return payload
                }
            }
        }
        return null
    }

    /** From MainActivity.onResume. */
    fun onResume() {
        if (readingWanted) enableReader()
        if (servingWanted) {
            preferVayu(true)
            listenOnly(true)
        }
    }

    /** From MainActivity.onPause. */
    fun onPause() {
        if (servingWanted) {
            preferVayu(false)
            listenOnly(false)
        }
        try {
            adapter?.disableReaderMode(activity)
        } catch (_: Exception) {}
    }

    // While Vayu shares something, prefer its card emulation over other apps
    // that register the same standard NDEF application.
    private fun preferVayu(on: Boolean) {
        val nfc = adapter ?: return
        try {
            val emulation = CardEmulation.getInstance(nfc)
            if (on) {
                emulation.setPreferredService(
                    activity,
                    ComponentName(activity, PairingHceService::class.java),
                )
            } else {
                emulation.unsetPreferredService(activity)
            }
        } catch (_: Exception) {
            // Not resumed or not supported: Android's default routing applies.
        }
    }

    /**
     * While this phone shares, it only listens (Android 15+). Two phones near
     * each other both poll and listen; when the sharing phone polled first it
     * read the other phone (which shares nothing) and held the link, so the
     * other phone never read the card or code. Reading screens use reader
     * mode, which already stops listening there.
     */
    private fun listenOnly(on: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.VANILLA_ICE_CREAM) return
        val nfc = adapter ?: return
        try {
            if (on) {
                nfc.setDiscoveryTechnology(
                    activity,
                    NfcAdapter.FLAG_READER_DISABLE,
                    NfcAdapter.FLAG_LISTEN_KEEP,
                )
            } else {
                nfc.resetDiscoveryTechnology(activity)
            }
        } catch (e: Exception) {
            // Not resumed or not supported: both modes stay on as before.
            Log.w(TAG, "Listen-only not applied: ${e.javaClass.simpleName}")
        }
    }

    fun unregister() {
        readingWanted = false
        servingWanted = false
        stopReading()
        PairingHceService.payload = null
        PairingHceService.ndefMessage = null
        methods?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        cardEvents?.setStreamHandler(null)
        methods = null
        events = null
        cardEvents = null
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
                // Pairing codes and receive tickets: Vayu-only, never a standard tag.
                PairingHceService.ndefMessage = null
                PairingHceService.payload = call.argument<ByteArray>("bytes")
                servingWanted = true
                preferVayu(true)
                listenOnly(true)
                result.success(true)
            }
            "serveCard" -> {
                val card = call.argument<ByteArray>("bytes")
                if (card == null || card.isEmpty() || card.size > MAX_PAYLOAD) {
                    result.error("INVALID", "Card missing or too large", null)
                    return
                }
                PairingHceService.payload = card
                PairingHceService.ndefMessage =
                    NdefMessage(NdefRecord.createMime(CARD_MIME, card)).toByteArray()
                servingWanted = true
                preferVayu(true)
                listenOnly(true)
                result.success(true)
            }
            "stopServing" -> {
                PairingHceService.payload = null
                PairingHceService.ndefMessage = null
                servingWanted = false
                preferVayu(false)
                listenOnly(false)
                result.success(true)
            }
            "takePendingCard" -> {
                val card = pendingCard
                pendingCard = null
                result.success(card)
            }
            "startReading" -> {
                val nfc = adapter
                if (nfc == null || !nfc.isEnabled) {
                    result.error("UNAVAILABLE", "NFC is off or missing", null)
                    return
                }
                readingWanted = true
                // A paused activity cannot enable reader mode; onResume will.
                enableReader()
                result.success(true)
            }
            "stopReading" -> {
                readingWanted = false
                stopReading()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun enableReader() {
        val nfc = adapter ?: return
        try {
            nfc.enableReaderMode(
                activity,
                { tag -> readPeer(tag) },
                NfcAdapter.FLAG_READER_NFC_A or NfcAdapter.FLAG_READER_NFC_B or
                    NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK,
                Bundle().apply {
                    putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY, PRESENCE_CHECK_MS)
                },
            )
        } catch (e: Exception) {
            Log.w(TAG, "Reader mode not enabled now: ${e.javaClass.simpleName}")
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
            if (!ok(iso.transceive(select))) {
                // A phone (or card) that is not sharing anything from Vayu.
                main.post { sink?.success("not_sharing") }
                return
            }
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
                val now = SystemClock.elapsedRealtime()
                val repeat = lastRead?.contentEquals(bytes) == true && now - lastReadAt < SAME_TAP_MS
                lastRead = bytes
                lastReadAt = now
                if (!repeat) main.post { sink?.success(bytes) }
            } else {
                main.post { sink?.success("read_incomplete") }
            }
        } catch (e: Exception) {
            // Usually the phones moved apart mid-read; the UI asks to hold still.
            Log.w(TAG, "Peer read failed: ${e.javaClass.simpleName}")
            main.post { sink?.success("read_failed") }
        } finally {
            try {
                iso.close()
            } catch (_: Exception) {}
        }
    }

    private fun ok(reply: ByteArray) =
        reply.size >= 2 && reply[reply.size - 2] == 0x90.toByte() && reply[reply.size - 1] == 0x00.toByte()
}
