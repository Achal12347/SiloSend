package com.achyrio.vayu.security

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * AES-256-GCM through the platform crypto provider, run on a background task queue.
 *
 * The pure-Dart cipher ran on the UI isolate at a few MB/s on phones, which capped
 * throughput and froze the UI during large transfers. The platform provider uses
 * hardware AES instructions. Output is standard GCM, byte-identical to the Dart cipher,
 * so peers using either implementation interoperate.
 */
class AeadHandler : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "com.achyrio.vayu/aead"
        private const val TAG_BITS = 128
        private const val TAG_BYTES = 16
    }

    private var channel: MethodChannel? = null

    fun register(messenger: BinaryMessenger) {
        val queue = messenger.makeBackgroundTaskQueue()
        channel = MethodChannel(messenger, CHANNEL, StandardMethodCodec.INSTANCE, queue).also {
            it.setMethodCallHandler(this)
        }
    }

    fun unregister() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val key = call.argument<ByteArray>("key")
        val nonce = call.argument<ByteArray>("nonce")
        val aad = call.argument<ByteArray>("aad")
        val data = call.argument<ByteArray>("data")
        if (key == null || key.size != 32 || nonce == null || nonce.size != 12 || aad == null || data == null) {
            result.error("INVALID_ARGS", "key(32), nonce(12), aad and data are required", null)
            return
        }
        when (call.method) {
            "encrypt" -> try {
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
                cipher.updateAAD(aad)
                // Returns ciphertext || 16-byte tag; Dart splits it.
                result.success(cipher.doFinal(data))
            } catch (e: Exception) {
                result.error("ENCRYPT_FAILED", e.javaClass.simpleName, null)
            }
            "decrypt" -> try {
                if (data.size < TAG_BYTES) {
                    result.error("AUTH_FAILED", "Ciphertext shorter than tag", null)
                    return
                }
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
                cipher.updateAAD(aad)
                result.success(cipher.doFinal(data))
            } catch (e: AEADBadTagException) {
                result.error("AUTH_FAILED", "Authentication tag mismatch", null)
            } catch (e: Exception) {
                result.error("DECRYPT_FAILED", e.javaClass.simpleName, null)
            }
            else -> result.notImplemented()
        }
    }
}
