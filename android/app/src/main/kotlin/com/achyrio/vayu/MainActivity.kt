package com.achyrio.vayu

import android.content.Intent
import com.achyrio.vayu.battery.BatteryHandler
import com.achyrio.vayu.connection.BleConnectionHandler
import com.achyrio.vayu.contacts.ContactsHandler
import com.achyrio.vayu.discovery.BleDiscoveryHandler
import com.achyrio.vayu.file.FileIoHandler
import com.achyrio.vayu.file.FilePickerHandler
import com.achyrio.vayu.file.ShareIntentHandler
import com.achyrio.vayu.file.StorageHandler
import com.achyrio.vayu.hotspot.HotspotHandler
import com.achyrio.vayu.pairing.NfcHandler
import com.achyrio.vayu.pairing.QrScannerHandler
import com.achyrio.vayu.platform.PlatformHandler
import com.achyrio.vayu.security.AeadHandler
import com.achyrio.vayu.security.SecureKeyStoreHandler
import com.achyrio.vayu.transfer.TransferServiceHandler
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var platformHandler: PlatformHandler? = null
    private var bleDiscoveryHandler: BleDiscoveryHandler? = null
    private var bleConnectionHandler: BleConnectionHandler? = null
    private var batteryHandler: BatteryHandler? = null
    private var filePickerHandler: FilePickerHandler? = null
    private var storageHandler: StorageHandler? = null
    private var transferServiceHandler: TransferServiceHandler? = null
    private var fileIoHandler: FileIoHandler? = null
    private var aeadHandler: AeadHandler? = null
    private var secureKeyStoreHandler: SecureKeyStoreHandler? = null
    private var hotspotHandler: HotspotHandler? = null
    private var qrScannerHandler: QrScannerHandler? = null
    private var nfcHandler: NfcHandler? = null
    private var shareIntentHandler: ShareIntentHandler? = null
    private var contactsHandler: ContactsHandler? = null

    // The real private files folder differs per Android user/work profile, so
    // Dart gets it from here instead of assuming /data/user/0.
    override fun getDartEntrypointArgs(): List<String> =
        listOf("--files-dir=${filesDir.absolutePath}")

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
        storageHandler = StorageHandler(this).apply {
            register(flutterEngine.dartExecutor.binaryMessenger)
        }
        transferServiceHandler = TransferServiceHandler(this).apply {
            register(flutterEngine.dartExecutor.binaryMessenger)
        }
        fileIoHandler = FileIoHandler(applicationContext).apply {
            register(flutterEngine.dartExecutor.binaryMessenger)
        }
        aeadHandler = AeadHandler().apply {
            register(flutterEngine.dartExecutor.binaryMessenger)
        }
        secureKeyStoreHandler = SecureKeyStoreHandler(applicationContext).apply {
            register(flutterEngine.dartExecutor.binaryMessenger)
        }
        hotspotHandler = HotspotHandler(this).apply {
            register(flutterEngine.dartExecutor.binaryMessenger)
        }
        qrScannerHandler = QrScannerHandler(this).apply {
            register(flutterEngine.dartExecutor.binaryMessenger)
        }
        nfcHandler = NfcHandler(this).apply {
            register(flutterEngine.dartExecutor.binaryMessenger)
        }
        contactsHandler = ContactsHandler(this).apply {
            register(flutterEngine.dartExecutor.binaryMessenger)
        }
        shareIntentHandler = ShareIntentHandler(this).apply {
            register(flutterEngine.dartExecutor.binaryMessenger)
            handle(intent)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        shareIntentHandler?.handle(intent)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (platformHandler?.onRequestPermissionsResult(requestCode, permissions, grantResults) == true) {
            return
        }
        if (transferServiceHandler?.onRequestPermissionsResult(requestCode, grantResults) == true) {
            return
        }
        if (storageHandler?.onRequestPermissionsResult(requestCode) == true) {
            return
        }
        if (hotspotHandler?.onRequestPermissionsResult(requestCode, grantResults) == true) {
            return
        }
        if (contactsHandler?.onRequestPermissionsResult(requestCode, grantResults) == true) {
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
        if (qrScannerHandler?.onActivityResult(requestCode, resultCode, data) == true) {
            return
        }
        if (contactsHandler?.onActivityResult(requestCode, resultCode, data) == true) {
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
        transferServiceHandler?.unregister()
        transferServiceHandler = null
        fileIoHandler?.unregister()
        fileIoHandler = null
        aeadHandler?.unregister()
        aeadHandler = null
        secureKeyStoreHandler?.unregister()
        secureKeyStoreHandler = null
        hotspotHandler?.unregister()
        hotspotHandler = null
        qrScannerHandler?.unregister()
        qrScannerHandler = null
        nfcHandler?.unregister()
        nfcHandler = null
        shareIntentHandler?.unregister()
        shareIntentHandler = null
        contactsHandler?.unregister()
        contactsHandler = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
