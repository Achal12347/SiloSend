package com.achyrio.vayu.file

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Receives files shared to Vayu from other apps (ACTION_SEND / ACTION_SEND_MULTIPLE),
 * and Receive codes (`vayu://pair` links) opened by another app, usually the
 * phone's camera after scanning a Receive QR code.
 *
 * The sending app grants read access to the shared URIs; Vayu reads them with
 * the same background reader as picked files. Shares that arrive before Flutter
 * is ready are held until Dart calls `takePending`; later shares are pushed
 * with `onShared`.
 */
class ShareIntentHandler(private val activity: Activity) : MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL = "com.achyrio.vayu/share_intent"
    }

    private var channel: MethodChannel? = null
    private var pending: List<Map<String, Any?>> = emptyList()
    private var dartReady = false
    private var pendingCode: String? = null
    private var codeReady = false

    fun register(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    fun unregister() {
        channel?.setMethodCallHandler(null)
        channel = null
        dartReady = false
        codeReady = false
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "takePending" -> {
                dartReady = true
                result.success(pending)
                pending = emptyList()
            }
            "takePendingCode" -> {
                codeReady = true
                result.success(pendingCode)
                pendingCode = null
            }
            else -> result.notImplemented()
        }
    }

    /** Called from MainActivity for the launch intent and every new intent. */
    fun handle(intent: Intent?) {
        if (intent == null) return
        receiveCode(intent)?.let { code ->
            // Consumed so a rotation or resume does not open it twice.
            intent.action = Intent.ACTION_MAIN
            intent.data = null
            if (codeReady && channel != null) {
                channel?.invokeMethod("onCode", code)
            } else {
                pendingCode = code
            }
            return
        }
        val docs = extract(intent)
        if (docs.isEmpty()) return
        // Consume the intent so a rotation or resume does not share the files twice.
        intent.action = Intent.ACTION_MAIN
        if (dartReady && channel != null) {
            channel?.invokeMethod("onShared", docs)
        } else {
            pending = docs
        }
    }

    /** A `vayu://pair` link, checked again in Dart before anything is joined. */
    private fun receiveCode(intent: Intent): String? {
        if (intent.action != Intent.ACTION_VIEW) return null
        val data = intent.data ?: return null
        if (data.scheme != "vayu" || data.host != "pair") return null
        return intent.dataString?.takeIf { it.length <= 2048 }
    }

    @Suppress("DEPRECATION")
    private fun extract(intent: Intent): List<Map<String, Any?>> {
        val uris = mutableListOf<Uri>()
        when (intent.action) {
            Intent.ACTION_SEND -> {
                val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
                uri?.let { uris.add(it) }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val list = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                }
                list?.let { uris.addAll(it) }
            }
            else -> return emptyList()
        }
        return uris.filter(::isForeignContent).mapNotNull { describe(it, intent.type) }
    }

    /**
     * Only content shared by another app. A file:// path or a link into Vayu's own
     * provider would let any app make Vayu offer its private files for sending.
     */
    private fun isForeignContent(uri: Uri): Boolean {
        if (uri.scheme != "content") return false
        val authority = uri.authority ?: return false
        return !authority.startsWith(activity.packageName)
    }

    private fun describe(uri: Uri, fallbackType: String?): Map<String, Any?>? {
        var name: String? = null
        var size = -1L
        try {
            activity.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeIdx = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (nameIdx >= 0) name = cursor.getString(nameIdx)
                    if (sizeIdx >= 0 && !cursor.isNull(sizeIdx)) size = cursor.getLong(sizeIdx)
                }
            }
        } catch (_: Exception) {
            // Unreadable share (permission revoked): skip rather than offer a dead file.
            return null
        }
        return mapOf(
            "uri" to uri.toString(),
            "name" to (name ?: uri.lastPathSegment ?: "shared_file"),
            "size" to size,
            "mimeType" to (activity.contentResolver.getType(uri) ?: fallbackType),
        )
    }
}
