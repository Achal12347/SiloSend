package com.achyrio.vayu.file

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
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
        const val REQUEST_CODE_PICK_FOLDER = 53533

        // Bounds a folder walk so a huge or looping tree cannot hang the app.
        private const val MAX_FOLDER_FILES = 20_000
        private const val MAX_FOLDER_DEPTH = 32
    }

    private var pendingFolderResult: MethodChannel.Result? = null
    private val main = Handler(Looper.getMainLooper())

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
            "pickFolder" -> {
                if (pendingFolderResult != null || pendingResult != null) {
                    result.error("ALREADY_PICKING", "A picker is already open", null)
                    return
                }
                pendingFolderResult = result
                try {
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                        flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                    }
                    activity.startActivityForResult(intent, REQUEST_CODE_PICK_FOLDER)
                } catch (e: Exception) {
                    pendingFolderResult = null
                    result.error("PICK_FAILED", "Failed to launch folder picker: ${e.message}", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == REQUEST_CODE_PICK_FOLDER) return onFolderPicked(resultCode, data)
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

    private fun onFolderPicked(resultCode: Int, data: Intent?): Boolean {
        val res = pendingFolderResult ?: return false
        pendingFolderResult = null
        val tree = data?.data
        if (resultCode != Activity.RESULT_OK || tree == null) {
            res.success(null)
            return true
        }
        try {
            activity.contentResolver.takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (_: SecurityException) {
            // The transient grant is enough for this send.
        }
        // A folder can hold thousands of files; walk it off the main thread.
        Thread {
            try {
                val root = DocumentsContract.getTreeDocumentId(tree)
                val rootName = displayName(tree, root) ?: "Folder"
                val files = mutableListOf<Map<String, Any?>>()
                walk(tree, root, "", 0, files)
                val truncated = files.size >= MAX_FOLDER_FILES
                main.post {
                    res.success(mapOf("name" to rootName, "files" to files, "truncated" to truncated))
                }
            } catch (e: Exception) {
                main.post { res.error("FOLDER_READ_FAILED", "Could not read the folder: ${e.message}", null) }
            }
        }.start()
        return true
    }

    private fun displayName(tree: Uri, documentId: String): String? {
        val uri = DocumentsContract.buildDocumentUriUsingTree(tree, documentId)
        activity.contentResolver.query(
            uri,
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor -> if (cursor.moveToFirst()) return cursor.getString(0) }
        return null
    }

    /** Lists every file under [parentId]; [path] is its folder path inside the picked folder. */
    private fun walk(
        tree: Uri,
        parentId: String,
        path: String,
        depth: Int,
        out: MutableList<Map<String, Any?>>,
    ) {
        if (depth > MAX_FOLDER_DEPTH || out.size >= MAX_FOLDER_FILES) return
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
        val columns = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
        )
        val folders = mutableListOf<Pair<String, String>>()
        activity.contentResolver.query(children, columns, null, null, null)?.use { cursor ->
            while (cursor.moveToNext() && out.size < MAX_FOLDER_FILES) {
                val id = cursor.getString(0) ?: continue
                val name = cursor.getString(1) ?: continue
                val mime = cursor.getString(2) ?: "application/octet-stream"
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    folders.add(id to name)
                } else {
                    out.add(
                        mapOf(
                            "uri" to DocumentsContract.buildDocumentUriUsingTree(tree, id).toString(),
                            "name" to name,
                            "size" to if (cursor.isNull(3)) -1L else cursor.getLong(3),
                            "mimeType" to mime,
                            "folder" to path,
                        )
                    )
                }
            }
        }
        for ((id, name) in folders) {
            walk(tree, id, if (path.isEmpty()) name else "$path/$name", depth + 1, out)
        }
    }
}
