package com.achyrio.vayu.file

import android.content.Context
import android.media.MediaScannerConnection
import android.os.Environment
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Handles resolution and management of public download destinations on Android
 * using system storage APIs across all API levels.
 */
class StorageHandler(private val context: Context) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "com.achyrio.vayu/storage"
    }

    private var channel: MethodChannel? = null

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
            "getDownloadsDirectory" -> {
                try {
                    val publicDownloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                    val siloSendDir = File(publicDownloads, "SiloSend")

                    val chosenDir = if ((siloSendDir.exists() || siloSendDir.mkdirs()) && siloSendDir.canWrite()) {
                        siloSendDir
                    } else {
                        // Safe app-specific external files dir fallback for strict scoped storage
                        val appDownloads = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                        File(appDownloads, "SiloSend").apply { mkdirs() }
                    }

                    result.success(chosenDir.absolutePath)
                } catch (e: Exception) {
                    result.error("STORAGE_ERROR", "Failed to resolve downloads directory: ${e.message}", null)
                }
            }
            "scanCompletedFile" -> {
                val filePath = call.argument<String>("path")
                if (filePath != null) {
                    try {
                        MediaScannerConnection.scanFile(
                            context,
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
}
