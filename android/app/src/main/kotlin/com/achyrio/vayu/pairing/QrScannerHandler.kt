package com.achyrio.vayu.pairing

import android.app.Activity
import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Channel `com.achyrio.vayu/qr_scanner`: opens [QrScanActivity] and returns the decoded text. */
class QrScannerHandler(private val activity: Activity) : MethodChannel.MethodCallHandler {
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
        val intent = Intent(activity, QrScanActivity::class.java)
            .putExtra(QrScanActivity.EXTRA_ACCEPT_CARDS, call.argument<Boolean>("cards") == true)
        activity.startActivityForResult(intent, REQUEST_CODE)
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
