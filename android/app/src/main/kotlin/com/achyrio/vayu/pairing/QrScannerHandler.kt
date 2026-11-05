package com.achyrio.vayu.pairing

import android.app.Activity
import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import com.achyrio.vayu.platform.PermissionGate

/** Channel `com.achyrio.vayu/qr_scanner`: opens [QrScanActivity] and returns the decoded text. */
class QrScannerHandler(
    private val activity: Activity,
    private val permissions: PermissionGate,
) : MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL = "com.achyrio.vayu/qr_scanner"
        private const val REQUEST_CODE = 4105
    }

    private var channel: MethodChannel? = null
    private var pending: MethodChannel.Result? = null

    fun register(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    fun unregister() {
        channel?.setMethodCallHandler(null)
        channel = null
        pending?.success(null)
        pending = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "scan") {
            result.notImplemented()
            return
        }
        if (pending != null) {
            result.error("ALREADY_SCANNING", "A scan is already open", null)
            return
        }
        pending = result
        permissions.request(PermissionGate.cameraPermissions()) { status ->
            if (pending !== result) return@request
            if (status != PermissionGate.GRANTED) {
                pending = null
                result.error("PERMISSION", "Camera permission was not granted", null)
                return@request
            }
            val intent = Intent(activity, QrScanActivity::class.java)
                .putExtra(QrScanActivity.EXTRA_ACCEPT_CARDS, call.argument<Boolean>("cards") == true)
            try {
                activity.startActivityForResult(intent, REQUEST_CODE)
            } catch (e: Exception) {
                // Keep a failed launch from blocking every later scan attempt.
                pending = null
                result.error(
                    "CAMERA_LAUNCH_FAILED",
                    "Could not open the QR scanner: ${e.message}",
                    null,
                )
            }
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pending ?: return true
        pending = null
        val error = data?.getStringExtra(QrScanActivity.EXTRA_ERROR)
        when {
            resultCode == Activity.RESULT_OK -> result.success(data?.getStringExtra(QrScanActivity.EXTRA_TEXT))
            error != null -> result.error(error.uppercase(), "Scanner closed: $error", null)
            else -> result.success(null) // User closed the scanner.
        }
        return true
    }
}
