package com.achyrio.vayu.discovery

import android.annotation.SuppressLint
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
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.ParcelUuid
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

class BleDiscoveryHandler(private val context: Context) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    companion object {
        private const val MAX_SCAN_STARTS = 4
        private const val SCAN_WINDOW_MS = 30_000L
        private const val MAX_SCAN_RETRIES = 3
        private const val TAG = "Vayu.BleDiscovery"
        private const val METHOD_CHANNEL = "com.achyrio.vayu/ble_discovery"
        private const val EVENT_CHANNEL = "com.achyrio.vayu/ble_scan_events"
        private const val SILOSEND_SERVICE_UUID = "00005353-0000-1000-8000-00805f9b34fb"

        // Second half of a beacon, in the scan response. It needs its own ID:
        // Android merges the advertisement and the scan response into one
        // record and keeps only one service-data entry per ID, so with one
        // shared ID a half was always lost.
        private const val BEACON_PART2_UUID = "00005354-0000-1000-8000-00805f9b34fb"

        // Bytes of a beacon placed in the advertisement itself. Connectable
        // advertising carries a 3-byte flags field: 31 - 3 - 4 leaves 24.
        private const val PART1_BYTES = 20

        // Most a scan response can carry as 16-bit service data (31 - 4).
        private const val PART2_MAX_BYTES = 27

        // Android: the same advertising callback is already running.
        private const val ADVERTISE_ALREADY_STARTED = 3
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

    // Android (7+) silently ignores an app's scans once it starts more than
    // 5 in 30 s: no results and no error, so Vayu looked alone. Starts are
    // kept under that, a running scan in the same mode is not restarted, and
    // a failed scan is retried a few times.
    private val scanStarts = ArrayDeque<Long>()
    private var pendingScanStart: Runnable? = null
    private var scanLowPower = false
    private var scanRetries = 0
    private var isAdvertising = false

    private val mainHandler = Handler(Looper.getMainLooper())

    // What Dart asked for, so a Bluetooth off/on restores it. Turning
    // Bluetooth off ends scans and advertising without any callback; the
    // flags then said "running" and nothing restarted them.
    private var scanWanted: Boolean? = null // low-power mode when wanted
    private var advertiseWanted: Pair<ByteArray, Boolean>? = null

    private val bluetoothState = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, intent: Intent?) {
            when (intent?.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1)) {
                BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF -> {
                    pendingScanStart?.let { mainHandler.removeCallbacks(it) }
                    pendingScanStart = null
                    isScanning = false
                    isAdvertising = false
                }
                BluetoothAdapter.STATE_ON -> {
                    scanWanted?.let { startScan(it, quietResult) }
                    advertiseWanted?.let { (bytes, saver) ->
                        startAdvertising(bytes, saver, quietResult)
                    }
                    Log.i(TAG, "Bluetooth back on: discovery restored")
                }
            }
        }
    }
    private var receiverRegistered = false

    /** For restarts nobody waits on. */
    private val quietResult = object : MethodChannel.Result {
        override fun success(result: Any?) {}
        override fun error(code: String, message: String?, details: Any?) {
            Log.w(TAG, "Restoring discovery failed: $code")
        }
        override fun notImplemented() {}
    }

    fun register(messenger: BinaryMessenger) {
        methodChannel = MethodChannel(messenger, METHOD_CHANNEL).apply {
            setMethodCallHandler(this@BleDiscoveryHandler)
        }
        eventChannel = EventChannel(messenger, EVENT_CHANNEL).apply {
            setStreamHandler(this@BleDiscoveryHandler)
        }
        if (!receiverRegistered) {
            ContextCompat.registerReceiver(
                context,
                bluetoothState,
                IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
            receiverRegistered = true
        }
    }

    fun unregister() {
        scanWanted = null
        advertiseWanted = null
        if (receiverRegistered) {
            try {
                context.unregisterReceiver(bluetoothState)
            } catch (_: Exception) {}
            receiverRegistered = false
        }
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
                scanWanted = batterySaver
                startScan(batterySaver, result)
            }
            "stopScan" -> {
                scanWanted = null
                stopScan()
                result.success(null)
            }
            "startAdvertising" -> {
                val beaconBytes = call.argument<ByteArray>("beaconBytes")
                val batterySaver = call.argument<Boolean>("batterySaver") ?: false
                if (beaconBytes != null) {
                    advertiseWanted = beaconBytes to batterySaver
                    startAdvertising(beaconBytes, batterySaver, result)
                } else {
                    result.error("INVALID_ARGUMENT", "beaconBytes parameter required", null)
                }
            }
            "stopAdvertising" -> {
                advertiseWanted = null
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
        if (isScanning && scanLowPower == batterySaver) {
            result.success(null)
            return
        }
        if (isScanning) stopScan()
        scanRetries = 0
        pendingScanStart?.let { mainHandler.removeCallbacks(it) }
        pendingScanStart = null
        val wait = scanThrottleDelayMs()
        if (wait > 0) {
            Log.i(TAG, "BLE scan starts in ${wait} ms (Android scan limit)")
            val start = Runnable {
                pendingScanStart = null
                beginScan(batterySaver, null)
            }
            pendingScanStart = start
            mainHandler.postDelayed(start, wait)
            result.success(null)
            return
        }
        beginScan(batterySaver, result)
    }

    /** How long until another scan start stays within Android's limit. */
    private fun scanThrottleDelayMs(): Long {
        val now = SystemClock.elapsedRealtime()
        while (scanStarts.isNotEmpty() && now - scanStarts.first() > SCAN_WINDOW_MS) {
            scanStarts.removeFirst()
        }
        if (scanStarts.size < MAX_SCAN_STARTS) return 0
        return SCAN_WINDOW_MS - (now - scanStarts.first()) + 250
    }

    @SuppressLint("MissingPermission")
    private fun beginScan(batterySaver: Boolean, result: MethodChannel.Result?) {
        val adapter = bluetoothAdapter
        if (adapter == null || !adapter.isEnabled) {
            result?.error("BLUETOOTH_DISABLED", "Bluetooth adapter is not enabled", null)
            return
        }
        scanner = adapter.bluetoothLeScanner

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
            scanStarts.addLast(SystemClock.elapsedRealtime())
            isScanning = true
            scanLowPower = batterySaver
            result?.success(null)
            Log.i(TAG, "BLE scan started successfully (lowPower: $batterySaver)")
        } catch (e: SecurityException) {
            result?.error("PERMISSION_DENIED", "Missing Bluetooth scan permission: ${e.message}", null)
        } catch (e: Exception) {
            result?.error("SCAN_ERROR", "Failed to start BLE scan: ${e.message}", null)
        }
    }

    // Any failure, a SecurityException included, is caught: stopping is best effort.
    @SuppressLint("MissingPermission")
    private fun stopScan() {
        pendingScanStart?.let { mainHandler.removeCallbacks(it) }
        pendingScanStart = null
        scanRetries = MAX_SCAN_RETRIES // a stopped scan is not retried
        if (!isScanning) return
        try {
            scanner?.stopScan(scanCallback)
        } catch (_: Exception) {}
        isScanning = false
        Log.i(TAG, "BLE scan stopped")
    }

    // Answered from the advertise callback, so Dart learns whether
    // advertising really started (it used to be told "started" either way).
    private var pendingAdvertiseResult: MethodChannel.Result? = null

    private fun answerAdvertise(error: String?, message: String?) {
        val pending = pendingAdvertiseResult ?: return
        pendingAdvertiseResult = null
        mainHandler.post {
            if (error == null) pending.success(null) else pending.error(error, message, null)
        }
    }

    private fun startAdvertising(beaconBytes: ByteArray, batterySaver: Boolean, result: MethodChannel.Result) {
        if (beaconBytes.size > PART1_BYTES + PART2_MAX_BYTES) {
            result.error("BEACON_TOO_LARGE", "Beacon is ${beaconBytes.size} bytes", null)
            return
        }
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
            // Connectable: phones that find this one connect to its GATT
            // server here (Bluetooth transfers and the Wi-Fi Direct
            // hand-over). Non-connectable advertising refused them.
            .setConnectable(true)
            .setTimeout(0)
            .build()

        val serviceUuid = ParcelUuid(UUID.fromString(SILOSEND_SERVICE_UUID))

        val advertiseData: AdvertiseData
        val scanResponseData: AdvertiseData?

        if (beaconBytes.size <= PART1_BYTES) {
            advertiseData = AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .addServiceData(serviceUuid, beaconBytes)
                .build()
            scanResponseData = null
        } else {
            val part1 = beaconBytes.copyOfRange(0, PART1_BYTES)
            val part2 = beaconBytes.copyOfRange(PART1_BYTES, beaconBytes.size)

            advertiseData = AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .addServiceData(serviceUuid, part1)
                .build()

            scanResponseData = AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .addServiceData(ParcelUuid(UUID.fromString(BEACON_PART2_UUID)), part2)
                .build()
        }

        // A call still waiting is superseded by this one.
        answerAdvertise(null, null)
        pendingAdvertiseResult = result
        try {
            if (scanResponseData != null) {
                advertiser?.startAdvertising(settings, advertiseData, scanResponseData, advertiseCallback)
            } else {
                advertiser?.startAdvertising(settings, advertiseData, advertiseCallback)
            }
            isAdvertising = true
            Log.i(TAG, "BLE advertising requested (bytes: ${beaconBytes.size})")
        } catch (e: SecurityException) {
            pendingAdvertiseResult = null
            result.error("PERMISSION_DENIED", "Missing Bluetooth advertise permission: ${e.message}", null)
        } catch (e: Exception) {
            pendingAdvertiseResult = null
            result.error("ADVERTISE_ERROR", "Failed to start BLE advertising: ${e.message}", null)
        }
    }

    @SuppressLint("MissingPermission")
    private fun stopAdvertising() {
        if (!isAdvertising) return
        try {
            advertiser?.stopAdvertising(advertiseCallback)
        } catch (_: Exception) {}
        isAdvertising = false
        Log.i(TAG, "BLE advertising stopped")
    }

    private val scanCallback = object : ScanCallback() {
        private val part1Uuid = ParcelUuid(UUID.fromString(SILOSEND_SERVICE_UUID))
        private val part2Uuid = ParcelUuid(UUID.fromString(BEACON_PART2_UUID))

        override fun onScanResult(callbackType: Int, result: ScanResult?) {
            result ?: return
            val record = result.scanRecord ?: return
            val address = result.device?.address ?: return

            val part1 = record.getServiceData(part1Uuid) ?: return
            // One record holds both halves once the scan response arrived;
            // until then the result is skipped (the next one completes it).
            val completeBeacon = if (part1.size > PART1_BYTES) {
                part1
            } else {
                val part2 = record.getServiceData(part2Uuid) ?: return
                part1 + part2
            }

            val eventMap = mapOf(
                "beaconBytes" to completeBeacon,
                "rssi" to result.rssi,
                "address" to address
            )
            mainHandler.post {
                eventSink?.success(eventMap)
            }
        }

        override fun onScanFailed(errorCode: Int) {
            Log.w(TAG, "BLE scan failed with error code: $errorCode")
            if (errorCode == SCAN_FAILED_ALREADY_STARTED) return
            // It is not scanning: say so, and try again a few times (the
            // controller is often only busy for a moment).
            isScanning = false
            if (scanRetries >= MAX_SCAN_RETRIES) return
            scanRetries++
            val lowPower = scanLowPower
            val retry = Runnable {
                pendingScanStart = null
                if (scanThrottleDelayMs() == 0L) beginScan(lowPower, null)
            }
            pendingScanStart = retry
            mainHandler.postDelayed(retry, 2_000L * scanRetries + scanThrottleDelayMs())
        }
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            Log.i(TAG, "BLE advertising started in effect")
            answerAdvertise(null, null)
        }

        override fun onStartFailure(errorCode: Int) {
            if (errorCode == ADVERTISE_ALREADY_STARTED) {
                answerAdvertise(null, null)
                return
            }
            Log.w(TAG, "BLE advertising failed with error code: $errorCode")
            isAdvertising = false
            answerAdvertise("ADVERTISE_FAILED", "Advertising failed (code $errorCode)")
        }
    }
}
