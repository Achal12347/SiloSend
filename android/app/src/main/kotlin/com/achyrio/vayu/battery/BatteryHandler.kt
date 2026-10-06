package com.achyrio.vayu.battery

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.PowerManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class BatteryHandler(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        private const val METHOD_CHANNEL = "com.achyrio.vayu/battery"
    }

    private var methodChannel: MethodChannel? = null

    fun register(messenger: BinaryMessenger) {
        methodChannel = MethodChannel(messenger, METHOD_CHANNEL).apply {
            setMethodCallHandler(this@BatteryHandler)
        }
    }

    fun unregister() {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getBatteryState" -> {
                val batteryState = queryBatteryState()
                result.success(batteryState)
            }
            else -> result.notImplemented()
        }
    }

    private fun queryBatteryState(): Map<String, Any?> {
        val intentFilter = IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        val batteryStatusIntent: Intent? = context.registerReceiver(null, intentFilter)

        var batteryLevel: Int? = null
        var isCharging: Boolean? = null

        if (batteryStatusIntent != null) {
            val level = batteryStatusIntent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
            val scale = batteryStatusIntent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
            if (level >= 0 && scale > 0) {
                batteryLevel = ((level.toFloat() / scale.toFloat()) * 100f).toInt().coerceIn(0, 100)
            }

            val status = batteryStatusIntent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
            val plugged = batteryStatusIntent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)
            isCharging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                    status == BatteryManager.BATTERY_STATUS_FULL ||
                    plugged > 0
        }

        val powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        val isPowerSaveMode: Boolean? = powerManager?.isPowerSaveMode

        return mapOf(
            "level" to batteryLevel,
            "isCharging" to isCharging,
            "isBatterySaverActive" to isPowerSaveMode
        )
    }
}
