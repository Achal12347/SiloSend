package com.achyrio.vayu.file

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.os.StatFs
import androidx.core.content.ContextCompat
import com.achyrio.vayu.platform.PermissionGate
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Resolves where received files are saved.
 *
 * Android 11+ lets apps create files in the public Downloads folder directly.
 * Android 8-10 needs WRITE_EXTERNAL_STORAGE (and legacy storage on Android 10);
 * without it files used to land silently in a hidden app-specific folder, which
 * looked like a failed transfer. The permission is requested the first time a
 * file is accepted, and the hidden folder is used only if the user declines.
 */
class StorageHandler(
    private val activity: Activity,
    private val permissions: PermissionGate,
) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "com.achyrio.vayu/storage"
        private const val FOLDER_NAME = "Vayu"
    }

    private var channel: MethodChannel? = null
    private val pendingDirectoryResults = mutableListOf<MethodChannel.Result>()

    fun register(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL)
        channel?.setMethodCallHandler(this)
    }

    fun unregister() {
        channel?.setMethodCallHandler(null)
        channel = null
        pendingDirectoryResults.clear()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getDownloadsDirectory" -> {
                if (needsLegacyWritePermission()) {
                    pendingDirectoryResults.add(result)
                    if (pendingDirectoryResults.size == 1) {
                        // Granted or not, every caller gets a folder: denial
                        // falls back to the app's own folder.
                        permissions.request(PermissionGate.storagePermissions()) {
                            val waiting = pendingDirectoryResults.toList()
                            pendingDirectoryResults.clear()
                            waiting.forEach { resolveDirectory(it) }
                        }
                    }
                    return
                }
                resolveDirectory(result)
            }
            "getFreeBytes" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("INVALID_ARGS", "Missing path parameter", null)
                    return
                }
                try {
                    // Walk up to the nearest existing folder; the Vayu folder may not exist yet.
                    var dir: File? = File(path)
                    while (dir != null && !dir.exists()) dir = dir.parentFile
                    val stat = StatFs((dir ?: Environment.getExternalStorageDirectory()).path)
                    result.success(stat.availableBytes)
                } catch (e: Exception) {
                    result.error("STAT_FAILED", "Cannot read free space: ${e.message}", null)
                }
            }
            "scanCompletedFile" -> {
                val filePath = call.argument<String>("path")
                if (filePath != null) {
                    try {
                        MediaScannerConnection.scanFile(
                            activity.applicationContext,
                            arrayOf(filePath),
                            null
                        ) { _, _ -> }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SCAN_ERROR", "Failed to scan file: ${e.message}", null)
                    }
                } else {
                    result.error("INVALID_ARGS", "Missing path parameter", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun needsLegacyWritePermission(): Boolean =
        Build.VERSION.SDK_INT <= Build.VERSION_CODES.Q &&
            ContextCompat.checkSelfPermission(activity, Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
            PackageManager.PERMISSION_GRANTED

    private fun resolveDirectory(result: MethodChannel.Result) {
        try {
            @Suppress("DEPRECATION")
            val publicDownloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            val publicDir = File(publicDownloads, FOLDER_NAME)

            val chosenDir = if ((publicDir.exists() || publicDir.mkdirs()) && publicDir.canWrite()) {
                publicDir
            } else {
                // App-specific folder: always writable, but only visible through Vayu.
                val appDownloads = activity.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                File(appDownloads, FOLDER_NAME).apply { mkdirs() }
            }

            result.success(chosenDir.absolutePath)
        } catch (e: Exception) {
            result.error("STORAGE_ERROR", "Failed to resolve downloads directory: ${e.message}", null)
        }
    }
}
