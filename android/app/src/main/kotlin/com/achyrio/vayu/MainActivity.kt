package com.achyrio.vayu

import android.content.Intent
import com.achyrio.vayu.battery.BatteryHandler
import com.achyrio.vayu.connection.BleConnectionHandler
import com.achyrio.vayu.discovery.BleDiscoveryHandler
import com.achyrio.vayu.file.FilePickerHandler
import com.achyrio.vayu.file.StorageHandler
import com.achyrio.vayu.platform.PlatformHandler
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
