package com.achyrio.vayu.pairing

import android.nfc.cardemulation.HostApduService
import android.os.Bundle

/**
 * Serves the current pairing payload over NFC by emulating an ISO-DEP card.
 *
 * Android removed phone-to-phone NDEF push (Beam) in Android 10, so the
 * showing phone acts as a card under Vayu's private AID and the joining phone
 * reads it in reader mode. The payload is only served while the pairing screen
 * is open ([payload] is null otherwise) and the manifest requires the device
 * to be unlocked.
 *
 * Commands (ISO 7816-4 framing):
 *  SELECT AID   00 A4 04 00 07 F0 56 41 59 55 50 01 -> 90 00 | 6A 82
 *  GET LENGTH   80 CA 00 00 02                       -> len(2) 90 00
 *  READ BINARY  00 B0 P1 P2 Le (offset = P1:P2)      -> data   90 00
 */
class PairingHceService : HostApduService() {
    companion object {
        val AID = byteArrayOf(0xF0.toByte(), 0x56, 0x41, 0x59, 0x55, 0x50, 0x01)
        private val OK = byteArrayOf(0x90.toByte(), 0x00)
        private val NOT_FOUND = byteArrayOf(0x6A, 0x82.toByte())
        private val BAD_COMMAND = byteArrayOf(0x6D, 0x00)
        private const val MAX_CHUNK = 240

        /** Set by [NfcHandler] while the pairing screen shows a code. */
        @Volatile
        var payload: ByteArray? = null
    }

    private var selected = false

    override fun processCommandApdu(command: ByteArray, extras: Bundle?): ByteArray {
        val current = payload ?: return NOT_FOUND
        if (command.size >= 4 && command[0] == 0x00.toByte() && command[1] == 0xA4.toByte()) {
            val lc = if (command.size > 4) command[4].toInt() and 0xFF else 0
            val aid = if (command.size >= 5 + lc) command.copyOfRange(5, 5 + lc) else ByteArray(0)
            selected = aid.contentEquals(AID)
            return if (selected) OK else NOT_FOUND
        }
        if (!selected) return NOT_FOUND
        if (command.size >= 4 && command[0] == 0x80.toByte() && command[1] == 0xCA.toByte()) {
            return byteArrayOf((current.size shr 8).toByte(), current.size.toByte()) + OK
        }
        if (command.size >= 4 && command[0] == 0x00.toByte() && command[1] == 0xB0.toByte()) {
            val offset = ((command[2].toInt() and 0xFF) shl 8) or (command[3].toInt() and 0xFF)
            if (offset >= current.size) return OK
            val end = minOf(current.size, offset + MAX_CHUNK)
            return current.copyOfRange(offset, end) + OK
        }
        return BAD_COMMAND
    }

    override fun onDeactivated(reason: Int) {
        selected = false
    }
}
