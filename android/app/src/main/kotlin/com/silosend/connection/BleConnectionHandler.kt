package com.silosend.connection

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.LinkedList
import java.util.Queue
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class BleConnectionHandler(private val context: Context) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        private const val TAG = "SiloSend.BleConnection"
        private const val METHOD_CHANNEL = "com.silosend/ble_connection"
        private const val EVENT_CHANNEL = "com.silosend/ble_connection_events"

        val SERVICE_UUID: UUID = UUID.fromString("00005353-0000-1000-8000-00805f9b34fb")
        val RX_CHAR_UUID: UUID = UUID.fromString("00005354-0000-1000-8000-00805f9b34fb")
        val TX_CHAR_UUID: UUID = UUID.fromString("00005355-0000-1000-8000-00805f9b34fb")
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        const val DEFAULT_ATT_MTU = 23
        const val TARGET_ATT_MTU = 512
        const val ATT_HEADER_SIZE = 3
    }

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null

    private val bluetoothManager: BluetoothManager? by lazy {
        context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    }
    private val bluetoothAdapter: BluetoothAdapter? get() = bluetoothManager?.adapter

    private var gattServer: BluetoothGattServer? = null
    private val activeClientGatts = ConcurrentHashMap<String, BluetoothGatt>()
    private val connectionMtus = ConcurrentHashMap<String, Int>()
    private val writeQueues = ConcurrentHashMap<String, Queue<ByteArray>>()
    private val pendingResults = ConcurrentHashMap<String, MethodChannel.Result>()
    private val isWriting = ConcurrentHashMap<String, Boolean>()

    private val mainHandler = Handler(Looper.getMainLooper())

    fun register(messenger: BinaryMessenger) {
        methodChannel = MethodChannel(messenger, METHOD_CHANNEL).apply {
            setMethodCallHandler(this@BleConnectionHandler)
        }
        eventChannel = EventChannel(messenger, EVENT_CHANNEL).apply {
            setStreamHandler(this@BleConnectionHandler)
        }
    }

    fun unregister() {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        closeAll()
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        this.eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        this.eventSink = null
    }

    private fun hasConnectPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(
                context,
                android.Manifest.permission.BLUETOOTH_CONNECT
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(
                context,
                android.Manifest.permission.BLUETOOTH
            ) == PackageManager.PERMISSION_GRANTED
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (!hasConnectPermission()) {
            result.error("PERMISSION_DENIED", "BLUETOOTH_CONNECT permission required", null)
            return
        }

        when (call.method) {
            "connect" -> {
                val address = call.argument<String>("address")
                if (address == null) {
                    result.error("INVALID_ARGUMENT", "Address must be provided", null)
                    return
                }
                val requestedMtu = call.argument<Int>("mtu") ?: TARGET_ATT_MTU
                connectGattClient(address, requestedMtu, result)
            }
            "disconnect" -> {
                val connectionId = call.argument<String>("connectionId")
                disconnect(connectionId)
                result.success(true)
            }
            "sendBytes" -> {
                val connectionId = call.argument<String>("connectionId")
                val data = call.argument<ByteArray>("data")
                if (connectionId == null || data == null) {
                    result.error("INVALID_ARGUMENT", "connectionId and data must be provided", null)
                    return
                }
                queueAndSendBytes(connectionId, data, result)
            }
            "startServer" -> {
                startGattServer(result)
            }
            "stopServer" -> {
                stopGattServer()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun connectGattClient(address: String, requestedMtu: Int, result: MethodChannel.Result) {
        val adapter = bluetoothAdapter
        if (adapter == null || !adapter.isEnabled) {
            result.error("BLUETOOTH_DISABLED", "Bluetooth is disabled or unavailable", null)
            return
        }

        try {
            val device = adapter.getRemoteDevice(address)
            val connectionId = "ble_$address"
            connectionMtus[connectionId] = DEFAULT_ATT_MTU
            writeQueues[connectionId] = LinkedList()
            isWriting[connectionId] = false

            val callback = object : BluetoothGattCallback() {
                override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                    if (newState == BluetoothProfile.STATE_CONNECTED) {
                        Log.i(TAG, "Connected to GATT server on $address, requesting MTU $requestedMtu...")
                        activeClientGatts[connectionId] = gatt
                        gatt.requestMtu(requestedMtu)
                        gatt.discoverServices()
                        emitEvent(mapOf(
                            "type" to "connected",
                            "connectionId" to connectionId,
                            "remoteAddress" to address,
                            "mtu" to (connectionMtus[connectionId] ?: DEFAULT_ATT_MTU)
                        ))
                    } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                        Log.i(TAG, "Disconnected from GATT on $address (status: $status)")
                        activeClientGatts.remove(connectionId)
                        connectionMtus.remove(connectionId)
                        writeQueues.remove(connectionId)
                        isWriting.remove(connectionId)
                        failPendingWrite(connectionId, "GATT disconnected")
                        gatt.close()
                        emitEvent(mapOf(
                            "type" to "disconnected",
                            "connectionId" to connectionId,
                            "reason" to "GATT disconnected (status $status)"
                        ))
                    }
                }

                override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
                    if (status == BluetoothGatt.GATT_SUCCESS) {
                        Log.i(TAG, "Negotiated ATT MTU for $connectionId: $mtu")
                        connectionMtus[connectionId] = mtu
                        emitEvent(mapOf(
                            "type" to "mtuChanged",
                            "connectionId" to connectionId,
                            "mtu" to mtu
                        ))
                    }
                }

                override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                    if (status == BluetoothGatt.GATT_SUCCESS) {
                        val service = gatt.getService(SERVICE_UUID)
                        val txChar = service?.getCharacteristic(TX_CHAR_UUID)
                        if (txChar != null) {
                            gatt.setCharacteristicNotification(txChar, true)
                            val cccd = txChar.getDescriptor(CCCD_UUID)
                            if (cccd != null) {
                                cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                                gatt.writeDescriptor(cccd)
                                Log.i(TAG, "Subscribed to SiloSend TX notifications on $connectionId")
                            }
                        }
                    }
                }

                @Deprecated("Deprecated in Java")
                override fun onCharacteristicChanged(
                    gatt: BluetoothGatt,
                    characteristic: BluetoothGattCharacteristic
                ) {
                    @Suppress("DEPRECATION")
                    val value = characteristic.value ?: return
                    emitEvent(mapOf(
                        "type" to "data",
                        "connectionId" to connectionId,
                        "data" to value
                    ))
                }

                override fun onCharacteristicWrite(
                    gatt: BluetoothGatt,
                    characteristic: BluetoothGattCharacteristic,
                    status: Int
                ) {
                    if (status == BluetoothGatt.GATT_SUCCESS) {
                        sendNextChunk(connectionId, gatt, characteristic)
                    } else {
                        Log.w(TAG, "Characteristic write failed on $connectionId: status $status")
                        failPendingWrite(connectionId, "Characteristic write failed (status: $status)")
                    }
                }
            }

            val gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
            } else {
                device.connectGatt(context, false, callback)
            }

            activeClientGatts[connectionId] = gatt
            result.success(connectionId)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to connect to BLE device: ${e.message}", e)
            result.error("CONNECT_FAILED", "Failed to connect to BLE device: ${e.message}", null)
        }
    }

    private fun queueAndSendBytes(connectionId: String, data: ByteArray, result: MethodChannel.Result) {
        val gatt = activeClientGatts[connectionId]
        if (gatt == null) {
            result.error("NOT_CONNECTED", "No active GATT connection for $connectionId", null)
            return
        }

        val service = gatt.getService(SERVICE_UUID)
        val characteristic = service?.getCharacteristic(RX_CHAR_UUID)
        if (characteristic == null) {
            result.error("SERVICE_NOT_FOUND", "SiloSend RX characteristic not found on remote GATT", null)
            return
        }

        val mtu = connectionMtus[connectionId] ?: DEFAULT_ATT_MTU
        val maxChunkSize = (mtu - ATT_HEADER_SIZE).coerceIn(20, 509)

        val queue = writeQueues.getOrPut(connectionId) { LinkedList() }
        synchronized(queue) {
            var offset = 0
            while (offset < data.size) {
                val chunkSize = minOf(maxChunkSize, data.size - offset)
                val chunk = ByteArray(chunkSize)
                System.arraycopy(data, offset, chunk, 0, chunkSize)
                queue.add(chunk)
                offset += chunkSize
            }
        }

        pendingResults[connectionId] = result

        if (isWriting[connectionId] != true) {
            sendNextChunk(connectionId, gatt, characteristic)
        }
    }

    private fun sendNextChunk(connectionId: String, gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
        val queue = writeQueues[connectionId] ?: return
        val nextChunk: ByteArray?
        synchronized(queue) {
            nextChunk = queue.poll()
        }

        if (nextChunk == null) {
            isWriting[connectionId] = false
            val pending = pendingResults.remove(connectionId)
            mainHandler.post {
                pending?.success(true)
            }
            return
        }

        isWriting[connectionId] = true

        @Suppress("DEPRECATION")
        characteristic.value = nextChunk
        characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT

        val initiated = gatt.writeCharacteristic(characteristic)
        if (!initiated) {
            Log.w(TAG, "Failed to initiate write on $connectionId")
            failPendingWrite(connectionId, "Failed to initiate characteristic write")
        }
    }

    private fun failPendingWrite(connectionId: String, reason: String) {
        isWriting[connectionId] = false
        val queue = writeQueues[connectionId]
        synchronized(queue ?: Any()) {
            queue?.clear()
        }
        val pending = pendingResults.remove(connectionId)
        mainHandler.post {
            pending?.error("WRITE_FAILED", reason, null)
        }
    }

    private fun disconnect(connectionId: String?) {
        if (connectionId == null) return
        val gatt = activeClientGatts.remove(connectionId)
        connectionMtus.remove(connectionId)
        writeQueues.remove(connectionId)
        isWriting.remove(connectionId)
        failPendingWrite(connectionId, "Disconnected by caller")

        try {
            gatt?.disconnect()
            gatt?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Error disconnecting GATT: ${e.message}")
        }
    }

    private fun startGattServer(result: MethodChannel.Result) {
        if (gattServer != null) {
            result.success(true)
            return
        }

        val manager = bluetoothManager
        if (manager == null) {
            result.error("BLUETOOTH_UNAVAILABLE", "Bluetooth manager unavailable", null)
            return
        }

        try {
            val server = manager.openGattServer(context, object : BluetoothGattServerCallback() {
                override fun onCharacteristicWriteRequest(
                    device: BluetoothDevice,
                    requestId: Int,
                    characteristic: BluetoothGattCharacteristic,
                    preparedWrite: Boolean,
                    responseNeeded: Boolean,
                    offset: Int,
                    value: ByteArray?
                ) {
                    if (responseNeeded) {
                        gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
                    }
                    if (value != null && value.isNotEmpty()) {
                        val connectionId = "ble_server_${device.address}"
                        emitEvent(mapOf(
                            "type" to "data",
                            "connectionId" to connectionId,
                            "data" to value
                        ))
                    }
                }

                override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
                    val connectionId = "ble_server_${device.address}"
                    if (newState == BluetoothProfile.STATE_CONNECTED) {
                        emitEvent(mapOf(
                            "type" to "connected",
                            "connectionId" to connectionId,
                            "remoteAddress" to device.address,
                            "mtu" to DEFAULT_ATT_MTU
                        ))
                    } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                        emitEvent(mapOf(
                            "type" to "disconnected",
                            "connectionId" to connectionId,
                            "reason" to "Client disconnected"
                        ))
                    }
                }

                override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
                    val connectionId = "ble_server_${device.address}"
                    connectionMtus[connectionId] = mtu
                    emitEvent(mapOf(
                        "type" to "mtuChanged",
                        "connectionId" to connectionId,
                        "mtu" to mtu
                    ))
                }
            })

            // Setup SiloSend GATT Service
            val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            val rxChar = BluetoothGattCharacteristic(
                RX_CHAR_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
                BluetoothGattCharacteristic.PERMISSION_WRITE
            )
            val txChar = BluetoothGattCharacteristic(
                TX_CHAR_UUID,
                BluetoothGattCharacteristic.PROPERTY_NOTIFY or BluetoothGattCharacteristic.PROPERTY_READ,
                BluetoothGattCharacteristic.PERMISSION_READ
            )
            val cccd = BluetoothGattDescriptor(
                CCCD_UUID,
                BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
            )
            txChar.addDescriptor(cccd)

            service.addCharacteristic(rxChar)
            service.addCharacteristic(txChar)
            server.addService(service)

            gattServer = server
            Log.i(TAG, "SiloSend GATT Server started successfully")
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start GATT server: ${e.message}", e)
            result.error("GATT_SERVER_FAILED", "Failed to start GATT server: ${e.message}", null)
        }
    }

    private fun stopGattServer() {
        try {
            gattServer?.close()
            gattServer = null
            Log.i(TAG, "GATT Server stopped")
        } catch (e: Exception) {
            Log.w(TAG, "Error closing GATT server: ${e.message}")
        }
    }

    private fun closeAll() {
        stopGattServer()
        for ((connectionId, gatt) in activeClientGatts) {
            try {
                failPendingWrite(connectionId, "Manager shutting down")
                gatt.disconnect()
                gatt.close()
            } catch (e: Exception) {
                // Ignore during shutdown
            }
        }
        activeClientGatts.clear()
        connectionMtus.clear()
        writeQueues.clear()
        isWriting.clear()
        pendingResults.clear()
    }

    private fun emitEvent(event: Map<String, Any?>) {
        mainHandler.post {
            eventSink?.success(event)
        }
    }
}
