package com.achyrio.vayu.file

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Handles document picking via the Android Storage Access Framework (SAF).
 *
 * Reading picked documents lives in [FileIoHandler], which runs off the main thread.
 */
class FilePickerHandler(private val activity: Activity) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "com.achyrio.vayu/file_picker"
        const val REQUEST_CODE_PICK_FILE = 53532
    }

    private var channel: MethodChannel? = null
    private var pendingResult: MethodChannel.Result? = null
    private var isMultipleSelection: Boolean = false

    fun register(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL)
        channel?.setMethodCallHandler(this)
    }

    fun unregister() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickDocument", "pickMultipleDocuments" -> {
                if (pendingResult != null) {
                    result.error("ALREADY_PICKING", "A file picking operation is already in progress", null)
                    return
                }
                pendingResult = result
                isMultipleSelection = call.method == "pickMultipleDocuments"
                try {
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                        if (isMultipleSelection) {
                            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                        }
                        flags = flags or Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                    }
                    activity.startActivityForResult(intent, REQUEST_CODE_PICK_FILE)
                } catch (e: Exception) {
                    pendingResult = null
                    result.error("PICK_FAILED", "Failed to launch document picker: ${e.message}", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE_PICK_FILE) return false

        val res = pendingResult ?: return false
        pendingResult = null

        if (resultCode != Activity.RESULT_OK || data == null) {
            if (isMultipleSelection) {
                res.success(emptyList<Map<String, Any?>>())
            } else {
                res.success(null)
            }
            return true
        }

        val uris = mutableListOf<Uri>()
        if (data.clipData != null) {
            val clip = data.clipData!!
            for (i in 0 until clip.itemCount) {
                val item = clip.getItemAt(i)
                if (item.uri != null) {
                    uris.add(item.uri)
                }
            }
        } else if (data.data != null) {
            uris.add(data.data!!)
        }

        if (uris.isEmpty()) {
            if (isMultipleSelection) {
                res.success(emptyList<Map<String, Any?>>())
            } else {
                res.success(null)
            }
            return true
        }

        try {
            val metadataList = mutableListOf<Map<String, Any?>>()
            for (uri in uris) {
                try {
                    activity.contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION
                    )
                } catch (_: SecurityException) {
                    // Transient permission preserved
                }

                var displayName = "unknown_file"
                var size: Long = -1L

                activity.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (nameIdx != -1) {
                            displayName = cursor.getString(nameIdx) ?: "unknown_file"
                        }
                        val sizeIdx = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (sizeIdx != -1 && !cursor.isNull(sizeIdx)) {
                            size = cursor.getLong(sizeIdx)
                        }
                    }
                }

                if (size <= 0) {
                    try {
                        activity.contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
                            size = pfd.statSize
                        }
                    } catch (_: Exception) {}
                }

                val mimeType = activity.contentResolver.getType(uri) ?: "application/octet-stream"

                metadataList.add(
                    mapOf(
                        "uri" to uri.toString(),
                        "name" to displayName,
                        "size" to size,
                        "mimeType" to mimeType
                    )
                )
            }

            if (isMultipleSelection) {
                res.success(metadataList)
            } else {
                res.success(metadataList.firstOrNull())
            }
        } catch (e: Exception) {
            res.error("METADATA_FAILED", "Failed to query document metadata: ${e.message}", null)
        }
        return true
    }

}
