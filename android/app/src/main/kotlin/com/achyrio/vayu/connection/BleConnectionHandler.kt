package com.achyrio.vayu.connection

import android.annotation.SuppressLint
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
import android.bluetooth.BluetoothStatusCodes
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
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Bidirectional BLE GATT link used as a Vayu transport.
 *
 * Each phone runs a GATT server. The connecting phone (client) writes to RX; the
 * accepting phone (server) answers through notifications on TX. Android allows one
 * outstanding GATT operation per link, so the client setup is a strict chain:
 * connect -> MTU -> discover services -> subscribe TX -> ready. The Dart connect call
 * completes only once that chain finishes, so the handshake never starts early.
 *
 * Events carry a "role" so client links and accepted server links are routed separately.
 */
// Every entry point (onMethodCall) checks BLUETOOTH_CONNECT first, and Android
// kills the process when a runtime permission is revoked, so GATT callbacks
// never run without it.
@SuppressLint("MissingPermission")
class BleConnectionHandler(private val context: Context) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        private const val TAG = "Vayu.BleConnection"
        private const val METHOD_CHANNEL = "com.achyrio.vayu/ble_connection"
        private const val EVENT_CHANNEL = "com.achyrio.vayu/ble_connection_events"

        val SERVICE_UUID: UUID = UUID.fromString("00005353-0000-1000-8000-00805f9b34fb")
        val RX_CHAR_UUID: UUID = UUID.fromString("00005354-0000-1000-8000-00805f9b34fb")
        val TX_CHAR_UUID: UUID = UUID.fromString("00005355-0000-1000-8000-00805f9b34fb")
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        const val DEFAULT_ATT_MTU = 23
        const val TARGET_ATT_MTU = 512
        const val ATT_HEADER_SIZE = 3
        const val CLIENT_PREFIX = "ble_"
        const val SERVER_PREFIX = "ble_server_"
    }

    /** Outgoing byte queue for one link, drained one GATT operation at a time. */
    private class Outbox {
        val chunks = LinkedList<ByteArray>()
        val waiting = LinkedList<Pair<Int, MethodChannel.Result>>() // remaining chunks -> caller
        var busy = false
    }

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null

    private val bluetoothManager: BluetoothManager? by lazy {
        context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    }
    private val bluetoothAdapter: BluetoothAdapter? get() = bluetoothManager?.adapter

    private var gattServer: BluetoothGattServer? = null
    private var serverTxCharacteristic: BluetoothGattCharacteristic? = null

    private val clientGatts = ConcurrentHashMap<String, BluetoothGatt>()
    private val pendingConnects = ConcurrentHashMap<String, MethodChannel.Result>()
    private val servicesRequested = ConcurrentHashMap<String, Boolean>()
    private val serverDevices = ConcurrentHashMap<String, BluetoothDevice>()
    private val subscribedServerLinks = ConcurrentHashMap<String, Boolean>()
    private val linkMtus = ConcurrentHashMap<String, Int>()
    private val outboxes = ConcurrentHashMap<String, Outbox>()

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
            true // BLUETOOTH is a normal install-time permission before Android 12.
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
                disconnect(call.argument<String>("connectionId"))
                result.success(true)
            }
            "sendBytes" -> {
                val connectionId = call.argument<String>("connectionId")
                val data = call.argument<ByteArray>("data")
                if (connectionId == null || data == null) {
                    result.error("INVALID_ARGUMENT", "connectionId and data must be provided", null)
                    return
                }
                if (connectionId.startsWith(SERVER_PREFIX)) {
                    queueServerNotification(connectionId, data, result)
                } else {
                    queueClientWrite(connectionId, data, result)
                }
            }
            "startServer" -> startGattServer(result)
            "stopServer" -> {
                stopGattServer()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    // ---------------------------------------------------------------- client role

    private fun connectGattClient(address: String, requestedMtu: Int, result: MethodChannel.Result) {
        val adapter = bluetoothAdapter
        if (adapter == null || !adapter.isEnabled) {
            result.error("BLUETOOTH_DISABLED", "Bluetooth is disabled or unavailable", null)
            return
        }
        val connectionId = CLIENT_PREFIX + address
        if (pendingConnects.containsKey(connectionId) || clientGatts.containsKey(connectionId)) {
            result.error("ALREADY_CONNECTING", "A link to $address already exists", null)
            return
        }

        try {
            val device = adapter.getRemoteDevice(address)
            linkMtus[connectionId] = DEFAULT_ATT_MTU
            outboxes[connectionId] = Outbox()
            pendingConnects[connectionId] = result

            val callback = object : BluetoothGattCallback() {
                override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                    if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                        clientGatts[connectionId] = gatt
                        // One GATT operation at a time: MTU first, services after it completes.
                        if (!gatt.requestMtu(requestedMtu)) {
                            requestServices(connectionId, gatt)
                        }
                    } else if (newState == BluetoothProfile.STATE_DISCONNECTED ||
                        status != BluetoothGatt.GATT_SUCCESS
                    ) {
                        Log.i(TAG, "Client link $connectionId closed (status $status)")
                        clientGatts.remove(connectionId)
                        servicesRequested.remove(connectionId)
                        try {
                            gatt.close()
                        } catch (_: Exception) {}
                        if (!failConnect(connectionId, "GATT connection failed (status $status)")) {
                            clearLink(connectionId, "GATT disconnected")
                            emitEvent(
                                mapOf(
                                    "role" to "client",
                                    "type" to "disconnected",
                                    "connectionId" to connectionId,
                                    "reason" to "GATT disconnected (status $status)",
                                )
                            )
                        }
                    }
                }

                override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
                    if (status == BluetoothGatt.GATT_SUCCESS) {
                        linkMtus[connectionId] = mtu
                        if (!pendingConnects.containsKey(connectionId)) {
                            emitEvent(
                                mapOf(
                                    "role" to "client",
                                    "type" to "mtuChanged",
                                    "connectionId" to connectionId,
                                    "mtu" to mtu,
                                )
                            )
                        }
                    }
                    requestServices(connectionId, gatt)
                }

                override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                    val txChar = gatt.getService(SERVICE_UUID)?.getCharacteristic(TX_CHAR_UUID)
                    val cccd = txChar?.getDescriptor(CCCD_UUID)
                    if (status != BluetoothGatt.GATT_SUCCESS || txChar == null || cccd == null) {
                        abortClient(connectionId, gatt, "Peer does not expose the Vayu GATT service")
                        return
                    }
                    if (!gatt.setCharacteristicNotification(txChar, true) || !writeCccd(gatt, cccd)) {
                        abortClient(connectionId, gatt, "Could not subscribe to peer notifications")
                    }
                }

                override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
                    if (descriptor.uuid != CCCD_UUID) return
                    if (status != BluetoothGatt.GATT_SUCCESS) {
                        abortClient(connectionId, gatt, "Peer rejected notification subscription ($status)")
                        return
                    }
                    val pending = pendingConnects.remove(connectionId) ?: return
                    val mtu = linkMtus[connectionId] ?: DEFAULT_ATT_MTU
                    Log.i(TAG, "Client link $connectionId ready (MTU $mtu)")
                    mainHandler.post { pending.success(mapOf("connectionId" to connectionId, "mtu" to mtu)) }
                }

                @Deprecated("Deprecated in Java")
                override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
                    // Android 13+ also delivers this legacy callback with the value set.
                    @Suppress("DEPRECATION")
                    val value = characteristic.value ?: return
                    emitEvent(
                        mapOf(
                            "role" to "client",
                            "type" to "data",
                            "connectionId" to connectionId,
                            "data" to value.copyOf(),
                        )
                    )
                }

                override fun onCharacteristicWrite(
                    gatt: BluetoothGatt,
                    characteristic: BluetoothGattCharacteristic,
                    status: Int,
                ) {
                    if (status == BluetoothGatt.GATT_SUCCESS) {
                        drainClient(connectionId, chunkCompleted = true)
                    } else {
                        failOutbox(connectionId, "Characteristic write failed (status $status)")
                    }
                }
            }

            device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
        } catch (e: Exception) {
            pendingConnects.remove(connectionId)
            clearLink(connectionId, "Connect failed")
            Log.e(TAG, "Failed to connect to BLE device: ${e.message}", e)
            result.error("CONNECT_FAILED", "Failed to connect to BLE device: ${e.message}", null)
        }
    }

    private fun requestServices(connectionId: String, gatt: BluetoothGatt) {
        if (servicesRequested.putIfAbsent(connectionId, true) != null) return
        if (!gatt.discoverServices()) {
            abortClient(connectionId, gatt, "Service discovery could not start")
        }
    }

    @Suppress("DEPRECATION")
    private fun writeCccd(gatt: BluetoothGatt, cccd: BluetoothGattDescriptor): Boolean {
        val enable = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeDescriptor(cccd, enable) == BluetoothStatusCodes.SUCCESS
        } else {
            cccd.value = enable
            gatt.writeDescriptor(cccd)
        }
    }

    private fun abortClient(connectionId: String, gatt: BluetoothGatt, reason: String) {
        Log.w(TAG, "Client link $connectionId aborted: $reason")
        failConnect(connectionId, reason)
        try {
            gatt.disconnect()
        } catch (_: Exception) {}
    }

    /** Fails a connect still awaiting readiness. Returns false if none was pending. */
    private fun failConnect(connectionId: String, reason: String): Boolean {
        val pending = pendingConnects.remove(connectionId) ?: return false
        clearLink(connectionId, reason)
        mainHandler.post { pending.error("CONNECT_FAILED", reason, null) }
        return true
    }

    private fun queueClientWrite(connectionId: String, data: ByteArray, result: MethodChannel.Result) {
        if (clientGatts[connectionId] == null || pendingConnects.containsKey(connectionId)) {
            result.error("NOT_CONNECTED", "No ready GATT link for $connectionId", null)
            return
        }
        enqueue(connectionId, data, result)
        drainClient(connectionId)
    }

    @Suppress("DEPRECATION")
    private fun drainClient(connectionId: String, chunkCompleted: Boolean = false) {
        val gatt = clientGatts[connectionId] ?: return
        val characteristic = gatt.getService(SERVICE_UUID)?.getCharacteristic(RX_CHAR_UUID)
        if (characteristic == null) {
            failOutbox(connectionId, "Peer RX characteristic not found")
            return
        }
        val chunk = nextChunk(connectionId, chunkCompleted) ?: return
        characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        val started = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeCharacteristic(characteristic, chunk, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) ==
                BluetoothStatusCodes.SUCCESS
        } else {
            characteristic.value = chunk
            gatt.writeCharacteristic(characteristic)
        }
        if (!started) failOutbox(connectionId, "Failed to start characteristic write")
    }

    // ---------------------------------------------------------------- server role

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
                override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
                    val connectionId = SERVER_PREFIX + device.address
                    if (newState == BluetoothProfile.STATE_CONNECTED) {
                        serverDevices[connectionId] = device
                        linkMtus[connectionId] = DEFAULT_ATT_MTU
                        outboxes[connectionId] = Outbox()
                        emitEvent(
                            mapOf(
                                "role" to "server",
                                "type" to "connected",
                                "connectionId" to connectionId,
                                "remoteAddress" to device.address,
                                "mtu" to DEFAULT_ATT_MTU,
                            )
                        )
                    } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                        serverDevices.remove(connectionId)
                        subscribedServerLinks.remove(connectionId)
                        clearLink(connectionId, "Client disconnected")
                        emitEvent(
                            mapOf(
                                "role" to "server",
                                "type" to "disconnected",
                                "connectionId" to connectionId,
                                "reason" to "Client disconnected",
                            )
                        )
                    }
                }

                override fun onCharacteristicWriteRequest(
                    device: BluetoothDevice,
                    requestId: Int,
                    characteristic: BluetoothGattCharacteristic,
                    preparedWrite: Boolean,
                    responseNeeded: Boolean,
                    offset: Int,
                    value: ByteArray?,
                ) {
                    if (responseNeeded) {
                        gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
                    }
                    if (characteristic.uuid == RX_CHAR_UUID && value != null && value.isNotEmpty()) {
                        emitEvent(
                            mapOf(
                                "role" to "server",
                                "type" to "data",
                                "connectionId" to SERVER_PREFIX + device.address,
                                "data" to value,
                            )
                        )
                    }
                }

                override fun onDescriptorWriteRequest(
                    device: BluetoothDevice,
                    requestId: Int,
                    descriptor: BluetoothGattDescriptor,
                    preparedWrite: Boolean,
                    responseNeeded: Boolean,
                    offset: Int,
                    value: ByteArray?,
                ) {
                    // Without this answer the client's subscription times out and it can
                    // never receive our replies.
                    if (descriptor.uuid == CCCD_UUID) {
                        val connectionId = SERVER_PREFIX + device.address
                        val enabled = value != null &&
                            value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                        if (enabled) subscribedServerLinks[connectionId] = true else subscribedServerLinks.remove(connectionId)
                    }
                    if (responseNeeded) {
                        gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
                    }
                }

                override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
                    val connectionId = SERVER_PREFIX + device.address
                    linkMtus[connectionId] = mtu
                    emitEvent(
                        mapOf(
                            "role" to "server",
                            "type" to "mtuChanged",
                            "connectionId" to connectionId,
                            "mtu" to mtu,
                        )
                    )
                }

                override fun onNotificationSent(device: BluetoothDevice, status: Int) {
                    val connectionId = SERVER_PREFIX + device.address
                    if (status == BluetoothGatt.GATT_SUCCESS) {
                        drainServer(connectionId, chunkCompleted = true)
                    } else {
                        failOutbox(connectionId, "Notification failed (status $status)")
                    }
                }
            })

            val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            val rxChar = BluetoothGattCharacteristic(
                RX_CHAR_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
                BluetoothGattCharacteristic.PERMISSION_WRITE,
            )
            val txChar = BluetoothGattCharacteristic(
                TX_CHAR_UUID,
                BluetoothGattCharacteristic.PROPERTY_NOTIFY or BluetoothGattCharacteristic.PROPERTY_READ,
                BluetoothGattCharacteristic.PERMISSION_READ,
            )
            txChar.addDescriptor(
                BluetoothGattDescriptor(
                    CCCD_UUID,
                    BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE,
                )
            )
            service.addCharacteristic(rxChar)
            service.addCharacteristic(txChar)
            server.addService(service)

            gattServer = server
            serverTxCharacteristic = txChar
            Log.i(TAG, "Vayu GATT server started")
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start GATT server: ${e.message}", e)
            result.error("GATT_SERVER_FAILED", "Failed to start GATT server: ${e.message}", null)
        }
    }

    private fun queueServerNotification(connectionId: String, data: ByteArray, result: MethodChannel.Result) {
        if (serverDevices[connectionId] == null) {
            result.error("NOT_CONNECTED", "No accepted GATT link for $connectionId", null)
            return
        }
        if (subscribedServerLinks[connectionId] != true) {
            result.error("NOT_SUBSCRIBED", "Peer has not subscribed to notifications yet", null)
            return
        }
        enqueue(connectionId, data, result)
        drainServer(connectionId)
    }

    @Suppress("DEPRECATION")
    private fun drainServer(connectionId: String, chunkCompleted: Boolean = false) {
        val server = gattServer ?: return
        val device = serverDevices[connectionId] ?: return
        val txChar = serverTxCharacteristic ?: return
        val chunk = nextChunk(connectionId, chunkCompleted) ?: return
        val started = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            server.notifyCharacteristicChanged(device, txChar, false, chunk) == BluetoothStatusCodes.SUCCESS
        } else {
            txChar.value = chunk
            server.notifyCharacteristicChanged(device, txChar, false)
        }
        if (!started) failOutbox(connectionId, "Failed to send notification")
    }

    private fun stopGattServer() {
        try {
            gattServer?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Error closing GATT server: ${e.message}")
        }
        gattServer = null
        serverTxCharacteristic = null
        serverDevices.keys.forEach { clearLink(it, "GATT server stopped") }
        serverDevices.clear()
        subscribedServerLinks.clear()
    }

    // ---------------------------------------------------------------- shared outbox

    private fun enqueue(connectionId: String, data: ByteArray, result: MethodChannel.Result) {
        val outbox = outboxes.getOrPut(connectionId) { Outbox() }
        val mtu = linkMtus[connectionId] ?: DEFAULT_ATT_MTU
        val maxChunk = (mtu - ATT_HEADER_SIZE).coerceIn(20, 509)
        synchronized(outbox) {
            var offset = 0
            var count = 0
            while (offset < data.size) {
                val size = minOf(maxChunk, data.size - offset)
                outbox.chunks.add(data.copyOfRange(offset, offset + size))
                offset += size
                count++
            }
            outbox.waiting.add(Pair(count, result))
        }
    }

    /**
     * Returns the next chunk to put on the air, or null when the link is busy or idle.
     *
     * [chunkCompleted] is true only from the GATT callback that confirms the in-flight
     * chunk; a plain enqueue while a chunk is in flight must not count as completion.
     */
    private fun nextChunk(connectionId: String, chunkCompleted: Boolean): ByteArray? {
        val outbox = outboxes[connectionId] ?: return null
        val completed = mutableListOf<MethodChannel.Result>()
        val chunk: ByteArray?
        synchronized(outbox) {
            if (outbox.busy && !chunkCompleted) return null
            if (outbox.busy) {
                // The in-flight chunk is confirmed: count it against its caller.
                outbox.busy = false
                val head = outbox.waiting.peekFirst()
                if (head != null) {
                    val remaining = head.first - 1
                    outbox.waiting.removeFirst()
                    if (remaining <= 0) completed.add(head.second) else outbox.waiting.addFirst(Pair(remaining, head.second))
                }
            }
            // Callers whose payload was empty complete immediately.
            while (outbox.waiting.peekFirst()?.first == 0) {
                completed.add(outbox.waiting.removeFirst().second)
            }
            chunk = outbox.chunks.poll()
            if (chunk != null) outbox.busy = true
        }
        if (completed.isNotEmpty()) mainHandler.post { completed.forEach { it.success(true) } }
        return chunk
    }

    private fun failOutbox(connectionId: String, reason: String) {
        val outbox = outboxes[connectionId] ?: return
        val failed: List<MethodChannel.Result>
        synchronized(outbox) {
            failed = outbox.waiting.map { it.second }
            outbox.waiting.clear()
            outbox.chunks.clear()
            outbox.busy = false
        }
        if (failed.isNotEmpty()) mainHandler.post { failed.forEach { it.error("WRITE_FAILED", reason, null) } }
    }

    private fun clearLink(connectionId: String, reason: String) {
        failOutbox(connectionId, reason)
        outboxes.remove(connectionId)
        linkMtus.remove(connectionId)
    }

    private fun disconnect(connectionId: String?) {
        if (connectionId == null) return
        if (connectionId.startsWith(SERVER_PREFIX)) {
            val device = serverDevices[connectionId]
            if (device != null) {
                try {
                    gattServer?.cancelConnection(device)
                } catch (_: Exception) {}
            }
            return
        }
        failConnect(connectionId, "Disconnected by caller")
        val gatt = clientGatts.remove(connectionId)
        servicesRequested.remove(connectionId)
        clearLink(connectionId, "Disconnected by caller")
        try {
            gatt?.disconnect()
            gatt?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Error disconnecting GATT: ${e.message}")
        }
    }

    private fun closeAll() {
        stopGattServer()
        for ((connectionId, gatt) in clientGatts) {
            try {
                gatt.disconnect()
                gatt.close()
            } catch (_: Exception) {}
            clearLink(connectionId, "Manager shutting down")
        }
        pendingConnects.keys.toList().forEach { failConnect(it, "Manager shutting down") }
        clientGatts.clear()
        servicesRequested.clear()
    }

    private fun emitEvent(event: Map<String, Any?>) {
        mainHandler.post {
            eventSink?.success(event)
        }
    }
}
