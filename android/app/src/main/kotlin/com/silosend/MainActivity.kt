package com.silosend

import com.silosend.discovery.BleDiscoveryHandler
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var bleDiscoveryHandler: BleDiscoveryHandler? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bleDiscoveryHandler = BleDiscoveryHandler(applicationContext).apply {
            register(flutterEngine.dartExecutor.binaryMessenger)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        bleDiscoveryHandler?.unregister()
        bleDiscoveryHandler = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
