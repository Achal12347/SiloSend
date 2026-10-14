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
 * Receives files shared to Vayu from other apps (ACTION_SEND / ACTION_SEND_MULTIPLE).
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

    fun register(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    fun unregister() {
        channel?.setMethodCallHandler(null)
        channel = null
        dartReady = false
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "takePending" -> {
                dartReady = true
                result.success(pending)
                pending = emptyList()
            }
            else -> result.notImplemented()
        }
    }

    /** Called from MainActivity for the launch intent and every new intent. */
    fun handle(intent: Intent?) {
        val docs = extract(intent ?: return)
        if (docs.isEmpty()) return
        // Consume the intent so a rotation or resume does not share the files twice.
        intent.action = Intent.ACTION_MAIN
        if (dartReady && channel != null) {
            channel?.invokeMethod("onShared", docs)
        } else {
            pending = docs
        }
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
        return uris.mapNotNull { describe(it, intent.type) }
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
