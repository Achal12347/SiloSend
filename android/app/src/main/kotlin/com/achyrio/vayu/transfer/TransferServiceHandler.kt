package com.achyrio.vayu.transfer

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Bridge that lets the Dart transfer coordinator start, update and stop
 * [TransferForegroundService], and ask once for the Android 13+ notification permission.
 */
class TransferServiceHandler(private val activity: Activity) : MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL = "com.achyrio.vayu/transfer_service"
        private const val REQUEST_CODE_NOTIFICATIONS = 4102
        private const val PREFS = "vayu_transfer_prefs"
        private const val KEY_ASKED_NOTIFICATIONS = "asked_notifications"
    }

    private var channel: MethodChannel? = null
    private var pendingNotificationResult: MethodChannel.Result? = null

    fun register(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    fun unregister() {
        channel?.setMethodCallHandler(null)
        channel = null
        pendingNotificationResult?.success(false)
        pendingNotificationResult = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start", "update" -> {
                val intent = Intent(activity, TransferForegroundService::class.java).apply {
                    action = if (call.method == "start") {
                        TransferForegroundService.ACTION_START
                    } else {
                        TransferForegroundService.ACTION_UPDATE
                    }
                    putExtra(TransferForegroundService.EXTRA_TITLE, call.argument<String>("title"))
                    putExtra(TransferForegroundService.EXTRA_TEXT, call.argument<String>("text"))
                    putExtra(TransferForegroundService.EXTRA_PROGRESS, call.argument<Int>("progress") ?: -1)
                }
                try {
                    ContextCompat.startForegroundService(activity, intent)
                    result.success(true)
                } catch (e: Exception) {
                    // Background start restrictions: report honestly instead of crashing.
                    result.success(false)
                }
            }
            "stop" -> {
                try {
                    activity.startService(
                        Intent(activity, TransferForegroundService::class.java).apply {
                            action = TransferForegroundService.ACTION_STOP
                        },
                    )
                } catch (_: Exception) {
                    activity.stopService(Intent(activity, TransferForegroundService::class.java))
                }
                result.success(true)
            }
            "requestNotificationPermission" -> requestNotificationPermission(result)
            else -> result.notImplemented()
        }
    }

    // Asked once only: the progress notification is optional, the service runs without it.
    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        val permission = Manifest.permission.POST_NOTIFICATIONS
        if (ContextCompat.checkSelfPermission(activity, permission) == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        val prefs = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.getBoolean(KEY_ASKED_NOTIFICATIONS, false) || pendingNotificationResult != null) {
            result.success(false)
            return
        }
        prefs.edit().putBoolean(KEY_ASKED_NOTIFICATIONS, true).apply()
        pendingNotificationResult = result
        ActivityCompat.requestPermissions(activity, arrayOf(permission), REQUEST_CODE_NOTIFICATIONS)
    }

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_CODE_NOTIFICATIONS) return false
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingNotificationResult?.success(granted)
        pendingNotificationResult = null
        return true
    }
}
