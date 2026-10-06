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
                val batterySaver = call.argument<Boolean>("batterySaver") ?: false
                startScan(batterySaver, result)
            }
            "stopScan" -> {
                stopScan()
                result.success(null)
            }
            "startAdvertising" -> {
                val beaconBytes = call.argument<ByteArray>("beaconBytes")
                val batterySaver = call.argument<Boolean>("batterySaver") ?: false
                if (beaconBytes != null) {
                    startAdvertising(beaconBytes, batterySaver, result)
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

    private fun startScan(batterySaver: Boolean, result: MethodChannel.Result) {
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

        val scanMode = if (batterySaver) {
            ScanSettings.SCAN_MODE_LOW_POWER
        } else {
            ScanSettings.SCAN_MODE_LOW_LATENCY
        }

        val settings = ScanSettings.Builder()
            .setScanMode(scanMode)
            .build()

        try {
            scanner?.startScan(listOf(filter), settings, scanCallback)
            isScanning = true
            result.success(null)
            Log.i(TAG, "BLE scan started successfully (lowPower: $batterySaver)")
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

    private fun startAdvertising(beaconBytes: ByteArray, batterySaver: Boolean, result: MethodChannel.Result) {
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

        val advertiseMode = if (batterySaver) {
            AdvertiseSettings.ADVERTISE_MODE_LOW_POWER
        } else {
            AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY
        }
        val txPower = if (batterySaver) {
            AdvertiseSettings.ADVERTISE_TX_POWER_LOW
        } else {
            AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM
        }

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(advertiseMode)
            .setTxPowerLevel(txPower)
            .setConnectable(false)
            .setTimeout(0)
            .build()

        val serviceUuid = ParcelUuid(UUID.fromString(SILOSEND_SERVICE_UUID))

        val advertiseData: AdvertiseData
        val scanResponseData: AdvertiseData?

        if (beaconBytes.size <= 24) {
            advertiseData = AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .addServiceData(serviceUuid, beaconBytes)
                .build()
            scanResponseData = null
        } else {
            val part1 = beaconBytes.copyOfRange(0, 20)
            val part2 = beaconBytes.copyOfRange(20, beaconBytes.size)

            advertiseData = AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .addServiceData(serviceUuid, part1)
                .build()

            scanResponseData = AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .addServiceData(serviceUuid, part2)
                .build()
        }

        try {
            if (scanResponseData != null) {
                advertiser?.startAdvertising(settings, advertiseData, scanResponseData, advertiseCallback)
            } else {
                advertiser?.startAdvertising(settings, advertiseData, advertiseCallback)
            }
            isAdvertising = true
            result.success(null)
            Log.i(TAG, "BLE advertising started successfully (bytes: ${beaconBytes.size})")
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
        private val pendingBeacons = mutableMapOf<String, ByteArray>()

        override fun onScanResult(callbackType: Int, result: ScanResult?) {
            result ?: return
            val record = result.scanRecord ?: return
            val address = result.device?.address ?: return

            val serviceUuid = ParcelUuid(UUID.fromString(SILOSEND_SERVICE_UUID))
            val serviceData = record.getServiceData(serviceUuid) ?: return

            var completeBeacon: ByteArray? = null
            if (serviceData.size >= 27) {
                // Already complete beacon
                completeBeacon = serviceData
            } else {
                // Reassemble primary + scan response fragments
                val existing = pendingBeacons[address]
                if (existing == null) {
                    pendingBeacons[address] = serviceData
                } else {
                    val combined = existing + serviceData
                    pendingBeacons.remove(address)
                    if (combined.size >= 27) {
                        completeBeacon = combined
                    }
                }
            }

            if (completeBeacon != null) {
                val eventMap = mapOf(
                    "beaconBytes" to completeBeacon,
                    "rssi" to result.rssi,
                    "address" to address
                )
                mainHandler.post {
                    eventSink?.success(eventMap)
                }
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
