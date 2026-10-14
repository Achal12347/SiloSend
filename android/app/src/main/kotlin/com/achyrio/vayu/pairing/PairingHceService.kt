package com.achyrio.vayu.pairing

import android.nfc.cardemulation.HostApduService
import android.os.Bundle

/**
 * Serves Vayu payloads over NFC by emulating an ISO-DEP card.
 *
 * Android removed phone-to-phone NDEF push (Beam) in Android 10, so the
 * sharing phone acts as a card and the other phone reads it. Two applications
 * are answered, each only while something is being shared ([payload] /
 * [ndefMessage] are null otherwise); the manifest requires the device to be
 * unlocked.
 *
 * 1. Vayu's private AID, read by Vayu in reader mode (pairing codes, receive
 *    tickets, cards):
 *    SELECT AID   00 A4 04 00 07 F0 56 41 59 55 50 01 -> 90 00 | 6A 82
 *    GET LENGTH   80 CA 00 00 02                       -> len(2) 90 00
 *    READ BINARY  00 B0 P1 P2 Le (offset = P1:P2)      -> data   90 00
 *
 * 2. The standard NFC Forum Type 4 Tag NDEF application (cards only), so a
 *    phone with Vayu closed reads the card through Android's own tag reader
 *    and Android opens Vayu for it:
 *    SELECT AID   00 A4 04 00 07 D2 76 00 00 85 01 01
 *    SELECT FILE  00 A4 00 0C 02 E1 03 (capability container) | E1 04 (NDEF)
 *    READ BINARY  00 B0 P1 P2 Le
 *    Writes are refused: the tag is read-only.
 */
class PairingHceService : HostApduService() {
    companion object {
        val AID = byteArrayOf(0xF0.toByte(), 0x56, 0x41, 0x59, 0x55, 0x50, 0x01)
        val NDEF_AID = byteArrayOf(0xD2.toByte(), 0x76, 0x00, 0x00, 0x85.toByte(), 0x01, 0x01)
        private val OK = byteArrayOf(0x90.toByte(), 0x00)
        private val NOT_FOUND = byteArrayOf(0x6A, 0x82.toByte())
        private val NOT_ALLOWED = byteArrayOf(0x69, 0x82.toByte())
        private val BAD_COMMAND = byteArrayOf(0x6D, 0x00)
        private const val MAX_CHUNK = 240
        private val CC_FILE = byteArrayOf(0xE1.toByte(), 0x03)
        private val NDEF_FILE = byteArrayOf(0xE1.toByte(), 0x04)

        /** Bytes served under the private AID; set by [NfcHandler]. */
        @Volatile
        var payload: ByteArray? = null

        /** NDEF message served as a standard tag (cards only); set by [NfcHandler]. */
        @Volatile
        var ndefMessage: ByteArray? = null
    }

    private enum class App { NONE, VAYU, NDEF }
    private enum class File { NONE, CC, NDEF }

    private var app = App.NONE
    private var file = File.NONE

    override fun processCommandApdu(command: ByteArray, extras: Bundle?): ByteArray {
        if (command.size < 4) return BAD_COMMAND
        val cla = command[0]
        val ins = command[1]
        val p1 = command[2]

        // SELECT by AID
        if (cla == 0x00.toByte() && ins == 0xA4.toByte() && p1 == 0x04.toByte()) {
            val aid = dataOf(command)
            app = when {
                aid.contentEquals(AID) && payload != null -> App.VAYU
                aid.contentEquals(NDEF_AID) && ndefMessage != null -> App.NDEF
                else -> App.NONE
            }
            file = File.NONE
            return if (app == App.NONE) NOT_FOUND else OK
        }

        return when (app) {
            App.VAYU -> vayuCommand(command)
            App.NDEF -> ndefCommand(command)
            App.NONE -> NOT_FOUND
        }
    }

    private fun vayuCommand(command: ByteArray): ByteArray {
        val current = payload ?: return NOT_FOUND
        if (command[0] == 0x80.toByte() && command[1] == 0xCA.toByte()) {
            return byteArrayOf((current.size shr 8).toByte(), current.size.toByte()) + OK
        }
        if (command[0] == 0x00.toByte() && command[1] == 0xB0.toByte()) {
            return readSlice(current, command)
        }
        return BAD_COMMAND
    }

    private fun ndefCommand(command: ByteArray): ByteArray {
        val message = ndefMessage ?: return NOT_FOUND
        val ins = command[1]
        // SELECT FILE by identifier (P1 = 00)
        if (command[0] == 0x00.toByte() && ins == 0xA4.toByte() && command[2] == 0x00.toByte()) {
            val id = dataOf(command)
            file = when {
                id.contentEquals(CC_FILE) -> File.CC
                id.contentEquals(NDEF_FILE) -> File.NDEF
                else -> File.NONE
            }
            return if (file == File.NONE) NOT_FOUND else OK
        }
        if (command[0] == 0x00.toByte() && ins == 0xB0.toByte()) {
            return when (file) {
                File.CC -> readSlice(capabilityContainer(message.size), command)
                File.NDEF -> readSlice(ndefFile(message), command)
                File.NONE -> NOT_FOUND
            }
        }
        // UPDATE BINARY and anything else: this tag is read-only.
        if (ins == 0xD6.toByte()) return NOT_ALLOWED
        return BAD_COMMAND
    }

    /** Capability container: mapping 2.0, read-only NDEF file E104. */
    private fun capabilityContainer(messageSize: Int): ByteArray {
        val maxFile = messageSize + 2
        return byteArrayOf(
            0x00, 0x0F, // CC length
            0x20, // mapping version 2.0
            0x00, MAX_CHUNK.toByte(), // MLe: max bytes per read
            0x00, MAX_CHUNK.toByte(), // MLc: max bytes per write
            0x04, 0x06, // NDEF file control TLV
            0xE1.toByte(), 0x04, // NDEF file id
            (maxFile shr 8).toByte(), maxFile.toByte(), // max NDEF file size
            0x00, // read access: granted
            0xFF.toByte(), // write access: none
        )
    }

    /** NDEF file: 2-byte length (NLEN) then the message. */
    private fun ndefFile(message: ByteArray): ByteArray =
        byteArrayOf((message.size shr 8).toByte(), message.size.toByte()) + message

    private fun readSlice(data: ByteArray, command: ByteArray): ByteArray {
        val offset = ((command[2].toInt() and 0xFF) shl 8) or (command[3].toInt() and 0xFF)
        if (offset >= data.size) return OK
        val requested = if (command.size >= 5) command[4].toInt() and 0xFF else MAX_CHUNK
        val length = if (requested == 0) MAX_CHUNK else minOf(requested, MAX_CHUNK)
        val end = minOf(data.size, offset + length)
        return data.copyOfRange(offset, end) + OK
    }

    private fun dataOf(command: ByteArray): ByteArray {
        val lc = if (command.size > 4) command[4].toInt() and 0xFF else 0
        return if (command.size >= 5 + lc) command.copyOfRange(5, 5 + lc) else ByteArray(0)
    }

    override fun onDeactivated(reason: Int) {
        app = App.NONE
        file = File.NONE
    }
}
