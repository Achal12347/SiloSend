package com.silosend

import android.content.Intent
import com.silosend.battery.BatteryHandler
import com.silosend.connection.BleConnectionHandler
import com.silosend.discovery.BleDiscoveryHandler
import com.silosend.file.FilePickerHandler
import com.silosend.file.StorageHandler
import com.silosend.platform.PlatformHandler
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var platformHandler: PlatformHandler? = null
    private var bleDiscoveryHandler: BleDiscoveryHandler? = null
    private var bleConnectionHandler: BleConnectionHandler? = null
    private var batteryHandler: BatteryHandler? = null
    private var filePickerHandler: FilePickerHandler? = null
    private var storageHandler: StorageHandler? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        platformHandler = PlatformHandler(this).apply {
            register(flutterEngine.dartExecutor.binaryMessenger)
        }
        bleDiscoveryHandler = BleDiscoveryHandler(applicationContext).apply {
            register(flutterEngine.dartExecutor.binaryMessenger)
        }
        bleConnectionHandler = BleConnectionHandler(applicationContext).apply {
            register(flutterEngine.dartExecutor.binaryMessenger)
        }
        batteryHandler = BatteryHandler(applicationContext).apply {
            register(flutterEngine.dartExecutor.binaryMessenger)
        }
        filePickerHandler = FilePickerHandler(this).apply {
            register(flutterEngine.dartExecutor.binaryMessenger)
        }
        storageHandler = StorageHandler(applicationContext).apply {
            register(flutterEngine.dartExecutor.binaryMessenger)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (platformHandler?.onRequestPermissionsResult(requestCode, permissions, grantResults) == true) {
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (platformHandler?.onActivityResult(requestCode, resultCode, data) == true) {
            return
        }
        if (filePickerHandler?.onActivityResult(requestCode, resultCode, data) == true) {
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        platformHandler?.unregister()
        platformHandler = null
        bleDiscoveryHandler?.unregister()
        bleDiscoveryHandler = null
        bleConnectionHandler?.unregister()
        bleConnectionHandler = null
        batteryHandler?.unregister()
        batteryHandler = null
        filePickerHandler?.unregister()
        filePickerHandler = null
        storageHandler?.unregister()
        storageHandler = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
