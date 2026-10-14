package com.achyrio.vayu.security

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Persists the 32-byte Ed25519 identity seed, wrapped by a non-exportable AES-256-GCM
 * key that lives in the Android Keystore (StrongBox when available).
 *
 * Only the wrapped seed is written to app-private preferences; the wrapping key never
 * leaves the secure hardware. Without persistence the identity key changed on every
 * launch, which made fingerprints, SAS verification and remembered peers meaningless.
 */
class SecureKeyStoreHandler(private val context: Context) : MethodChannel.MethodCallHandler {
    companion object {
        private const val TAG = "Vayu.SecureKeyStore"
        private const val CHANNEL = "com.achyrio.vayu/secure_key_store"
        private const val KEYSTORE = "AndroidKeyStore"
        private const val WRAP_KEY_ALIAS = "vayu_identity_seed_wrap_v1"
        private const val PREFS = "vayu_secure_store"
        private const val PREF_WRAPPED_SEED = "identity_seed_v1"
        private const val GCM_TAG_BITS = 128
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
        when (call.method) {
            "load" -> try {
                result.success(load())
            } catch (e: Exception) {
                // An unreadable seed (e.g. Keystore key lost after a restore) is reported as
                // absent so a fresh identity is minted; peers will see the new key honestly.
                Log.w(TAG, "Stored identity seed unreadable: ${e.javaClass.simpleName}")
                clear()
                result.success(null)
            }
            "save" -> {
                val seed = call.argument<ByteArray>("seed")
                if (seed == null || seed.size != 32) {
                    result.error("INVALID_ARGS", "seed must be 32 bytes", null)
                    return
                }
                try {
                    save(seed)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("SAVE_FAILED", e.javaClass.simpleName, null)
                } finally {
                    seed.fill(0)
                }
            }
            "clear" -> {
                clear()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun prefs() = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun load(): ByteArray? {
        val stored = prefs().getString(PREF_WRAPPED_SEED, null) ?: return null
        val blob = Base64.decode(stored, Base64.NO_WRAP)
        val iv = blob.copyOfRange(0, 12)
        val sealed = blob.copyOfRange(12, blob.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, wrappingKey(create = false), GCMParameterSpec(GCM_TAG_BITS, iv))
        return cipher.doFinal(sealed)
    }

    private fun save(seed: ByteArray) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, wrappingKey(create = true))
        val sealed = cipher.doFinal(seed)
        val blob = cipher.iv + sealed
        prefs().edit().putString(PREF_WRAPPED_SEED, Base64.encodeToString(blob, Base64.NO_WRAP)).commit()
    }

    private fun clear() {
        prefs().edit().remove(PREF_WRAPPED_SEED).commit()
        try {
            KeyStore.getInstance(KEYSTORE).apply { load(null) }.deleteEntry(WRAP_KEY_ALIAS)
        } catch (_: Exception) {}
    }

    private fun wrappingKey(create: Boolean): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (keyStore.getKey(WRAP_KEY_ALIAS, null) as? SecretKey)?.let { return it }
        if (!create) throw IllegalStateException("Wrapping key missing")
        return try {
            generateKey(strongBox = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
        } catch (e: Exception) {
            // Most phones have no StrongBox; the TEE-backed Keystore is the fallback.
            generateKey(strongBox = false)
        }
    }

    private fun generateKey(strongBox: Boolean): SecretKey {
        val spec = KeyGenParameterSpec.Builder(
            WRAP_KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setRandomizedEncryptionRequired(true)
            .apply {
                if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    setIsStrongBoxBacked(true)
                }
            }
            .build()
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE).run {
            init(spec)
            generateKey()
        }
    }
}
