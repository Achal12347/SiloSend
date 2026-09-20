package com.silosend.discovery

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

class BleDiscoveryHandler(private val context: Context) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    companion object {
        private const val TAG = "SiloSend.BleDiscovery"
        private const val METHOD_CHANNEL = "com.silosend/ble_discovery"
        private const val EVENT_CHANNEL = "com.silosend/ble_scan_events"
        private const val SILOSEND_SERVICE_UUID = "00005353-0000-1000-8000-00805f9b34fb"
    }

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null

    private val bluetoothManager: BluetoothManager? by lazy {
        context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    }
    private val bluetoothAdapter: BluetoothAdapter? get() = bluetoothManager?.adapter

    private var scanner: BluetoothLeScanner? = null
    private var advertiser: BluetoothLeAdvertiser? = null

    private var isScanning = false
    private var isAdvertising = false

    private val mainHandler = Handler(Looper.getMainLooper())

    fun register(messenger: BinaryMessenger) {
        methodChannel = MethodChannel(messenger, METHOD_CHANNEL).apply {
            setMethodCallHandler(this@BleDiscoveryHandler)
        }
        eventChannel = EventChannel(messenger, EVENT_CHANNEL).apply {
            setStreamHandler(this@BleDiscoveryHandler)
        }
    }

    fun unregister() {
        stopScan()
        stopAdvertising()
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startScan" -> {
                startScan(result)
            }
            "stopScan" -> {
                stopScan()
                result.success(null)
            }
            "startAdvertising" -> {
                val beaconBytes = call.argument<ByteArray>("beaconBytes")
                if (beaconBytes != null) {
                    startAdvertising(beaconBytes, result)
                } else {
                    result.error("INVALID_ARGUMENT", "beaconBytes parameter required", null)
                }
            }
            "stopAdvertising" -> {
                stopAdvertising()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun startScan(result: MethodChannel.Result) {
        val adapter = bluetoothAdapter
        if (adapter == null || !adapter.isEnabled) {
            result.error("BLUETOOTH_DISABLED", "Bluetooth adapter is not enabled", null)
            return
        }

        scanner = adapter.bluetoothLeScanner
        if (scanner == null) {
            result.error("BLE_NOT_SUPPORTED", "BLE scanner unavailable on this device", null)
            return
        }

        val serviceUuid = ParcelUuid(UUID.fromString(SILOSEND_SERVICE_UUID))
        val filter = ScanFilter.Builder()
            .setServiceData(serviceUuid, null)
            .build()

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        try {
            scanner?.startScan(listOf(filter), settings, scanCallback)
            isScanning = true
            result.success(null)
            Log.i(TAG, "BLE scan started successfully")
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", "Missing Bluetooth scan permission: ${e.message}", null)
        } catch (e: Exception) {
            result.error("SCAN_ERROR", "Failed to start BLE scan: ${e.message}", null)
        }
    }

    private fun stopScan() {
        if (!isScanning) return
        try {
            scanner?.stopScan(scanCallback)
        } catch (_: Exception) {}
        isScanning = false
        Log.i(TAG, "BLE scan stopped")
    }

    private fun startAdvertising(beaconBytes: ByteArray, result: MethodChannel.Result) {
        val adapter = bluetoothAdapter
        if (adapter == null || !adapter.isEnabled) {
            result.error("BLUETOOTH_DISABLED", "Bluetooth adapter is not enabled", null)
            return
        }

        advertiser = adapter.bluetoothLeAdvertiser
        if (advertiser == null) {
            result.error("ADVERTISING_NOT_SUPPORTED", "BLE advertising not supported on this device hardware", null)
            return
        }

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(false)
            .setTimeout(0)
            .build()

        val serviceUuid = ParcelUuid(UUID.fromString(SILOSEND_SERVICE_UUID))
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addServiceData(serviceUuid, beaconBytes)
            .build()

        try {
            advertiser?.startAdvertising(settings, data, advertiseCallback)
            isAdvertising = true
            result.success(null)
            Log.i(TAG, "BLE advertising started successfully")
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", "Missing Bluetooth advertise permission: ${e.message}", null)
        } catch (e: Exception) {
            result.error("ADVERTISE_ERROR", "Failed to start BLE advertising: ${e.message}", null)
        }
    }

    private fun stopAdvertising() {
        if (!isAdvertising) return
        try {
            advertiser?.stopAdvertising(advertiseCallback)
        } catch (_: Exception) {}
        isAdvertising = false
        Log.i(TAG, "BLE advertising stopped")
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult?) {
            result ?: return
            val record = result.scanRecord ?: return

            val serviceUuid = ParcelUuid(UUID.fromString(SILOSEND_SERVICE_UUID))
            val serviceData = record.getServiceData(serviceUuid) ?: return

            val eventMap = mapOf(
                "beaconBytes" to serviceData,
                "rssi" to result.rssi,
                "address" to (result.device?.address ?: "")
            )

            mainHandler.post {
                eventSink?.success(eventMap)
            }
        }

        override fun onScanFailed(errorCode: Int) {
            Log.w(TAG, "BLE scan failed with error code: $errorCode")
        }
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            Log.i(TAG, "BLE advertising started in effect")
        }

        override fun onStartFailure(errorCode: Int) {
            Log.w(TAG, "BLE advertising failed with error code: $errorCode")
            isAdvertising = false
        }
    }
}
