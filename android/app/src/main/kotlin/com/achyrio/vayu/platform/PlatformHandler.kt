package com.achyrio.vayu.platform

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.wifi.WifiManager
import android.nfc.NfcAdapter
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * Handles system hardware capabilities, runtime permissions, Bluetooth lifecycle,
 * system settings navigation, and document viewing.
 *
 * Adheres strictly to the Vayu principle:
 * - Never forces unnecessary system settings or permissions.
 * - Distinguishes between Android 12+ (API 31+) and legacy Android versions.
 * - Does not loop or block discovery across transports.
 */
class PlatformHandler(
    private val activity: Activity,
    private val permissions: PermissionGate,
) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "com.achyrio.vayu/platform"
        const val REQUEST_CODE_ENABLE_BLUETOOTH = 1002
    }

    private var channel: MethodChannel? = null
    private var pendingEnableBtResult: MethodChannel.Result? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    private val bluetoothManager: BluetoothManager? by lazy {
        activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    }
    private val bluetoothAdapter: BluetoothAdapter? get() = bluetoothManager?.adapter

    fun register(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL)
        channel?.setMethodCallHandler(this)
    }

    fun unregister() {
        releaseMulticastLock()
        channel?.setMethodCallHandler(null)
        channel = null
        pendingEnableBtResult = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkCapabilities" -> {
                try {
                    result.success(getCapabilitiesMap())
                } catch (e: Exception) {
                    result.error("CAPABILITY_CHECK_FAILED", e.message, null)
                }
            }
            "requestNearbyPermissions" -> {
                permissions.request(PermissionGate.nearbyPermissions()) { result.success(it) }
            }
            "permissionReport" -> {
                try {
                    result.success(permissionReport())
                } catch (e: Exception) {
                    result.error("REPORT_FAILED", e.message, null)
                }
            }
            "requestPermissionGroup" -> {
                val group = call.argument<String>("group")
                val wanted = group?.let { PermissionGate.permissionsFor(it) }
                if (wanted == null) {
                    result.error("INVALID_ARGS", "Unknown permission group: $group", null)
                } else {
                    permissions.request(wanted) { result.success(it) }
                }
            }
            "openUri" -> {
                val uri = call.argument<String>("uri")
                result.success(uri != null && openUri(uri))
            }
            "openSettingsPage" -> {
                val page = call.argument<String>("page") ?: "app"
                result.success(openSettingsPage(page))
            }
            "enableBluetooth" -> {
                requestEnableBluetooth(result)
            }
            "openAppSettings" -> {
                try {
                    val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                        data = Uri.fromParts("package", activity.packageName, null)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    activity.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("OPEN_SETTINGS_FAILED", e.message, null)
                }
            }
            "openLocationSettings" -> {
                try {
                    val intent = Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    activity.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("OPEN_LOCATION_SETTINGS_FAILED", e.message, null)
                }
            }
            "openWifiSettings" -> {
                try {
                    val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        Intent(Settings.Panel.ACTION_INTERNET_CONNECTIVITY).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                    } else {
                        Intent(Settings.ACTION_WIFI_SETTINGS).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                    }
                    activity.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("OPEN_WIFI_SETTINGS_FAILED", e.message, null)
                }
            }
            "openFile" -> {
                val filePath = call.argument<String>("path")
                val mimeType = call.argument<String>("mimeType") ?: "*/*"
                if (filePath == null) {
                    result.error("INVALID_ARGS", "File path must be provided", null)
                    return
                }
                openFileWithIntent(filePath, mimeType, result)
            }
            "acquireMulticastLock" -> {
                acquireMulticastLock()
                result.success(true)
            }
            "releaseMulticastLock" -> {
                releaseMulticastLock()
                result.success(true)
            }
            "wifiLinkInfo" -> result.success(wifiLinkInfo())
            else -> result.notImplemented()
        }
    }

    /**
     * Band and negotiated speed of the current Wi-Fi connection, for the speed
     * diagnostics. Frequency and link speed need no location permission (only
     * the network name would). Null when not on Wi-Fi.
     */
    private fun wifiLinkInfo(): Map<String, Any?>? {
        return try {
            val wifi = activity.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            val info = wifi.connectionInfo ?: return null
            if (info.networkId == -1 && info.linkSpeed <= 0) return null
            mapOf(
                "frequencyMhz" to info.frequency,
                "linkSpeedMbps" to info.linkSpeed,
                "txLinkSpeedMbps" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) info.txLinkSpeedMbps else null,
                "rxLinkSpeedMbps" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) info.rxLinkSpeedMbps else null,
                "rssi" to info.rssi,
            )
        } catch (e: Exception) {
            null
        }
    }

    private fun getCapabilitiesMap(): Map<String, Any?> {
        val hasBleHardware = activity.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE) &&
                (bluetoothAdapter != null)
        val isBtEnabled = bluetoothAdapter?.isEnabled == true
        val nearbyStatus = checkNearbyPermissionStatus()
        val locRequired = isLocationRequiredForBle()
        val locEnabled = isLocationEnabled()
        val wifiOn = isWifiEnabled()
        val lanAvail = isLanAvailable()

        return mapOf(
            "bluetoothSupported" to hasBleHardware,
            "bluetoothEnabled" to isBtEnabled,
            "nearbyPermissionStatus" to nearbyStatus,
            "locationRequired" to locRequired,
            "locationEnabled" to locEnabled,
            "wifiEnabled" to wifiOn,
            "lanAvailable" to lanAvail,
            "sdkVersion" to Build.VERSION.SDK_INT
        )
    }

    private fun isLocationRequiredForBle(): Boolean {
        // Android 12+ (API 31+) declares neverForLocation in Manifest; location is NOT required for BLE.
        // Android 8.0-11 (API 26-30) requires ACCESS_FINE_LOCATION and Location Services for BLE discovery.
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.S
    }

    private fun checkNearbyPermissionStatus(): String =
        permissions.status(PermissionGate.nearbyPermissions())

    /**
     * Everything Vayu needs, each as a status string, for the Permissions &
     * settings screen. Switches report on / off / unsupported / not_needed.
     */
    private fun permissionReport(): Map<String, Any?> {
        val sdk = Build.VERSION.SDK_INT
        val nfc = NfcAdapter.getDefaultAdapter(activity)
        val power = activity.getSystemService(Context.POWER_SERVICE) as? PowerManager
        // Location services must be on for Bluetooth scans before Android 12
        // and for phone-to-phone Wi-Fi before Android 13.
        val locationNeeded = sdk < Build.VERSION_CODES.TIRAMISU
        // Groups refused once that Android will still ask for: the app should
        // explain why before asking again.
        val rationale = listOf("nearby", "directWifi", "camera", "notifications", "storage")
            .filter { group ->
                PermissionGate.permissionsFor(group)?.let { permissions.rationale(it) } == true
            }
        return mapOf(
            "rationale" to rationale,
            "sdkVersion" to sdk,
            "nearby" to permissions.status(PermissionGate.nearbyPermissions()),
            // Before Android 12 this is the same location permission as "nearby".
            "directWifi" to if (sdk < Build.VERSION_CODES.S) {
                PermissionGate.NOT_NEEDED
            } else {
                permissions.status(PermissionGate.directWifiPermissions())
            },
            "camera" to permissions.status(PermissionGate.cameraPermissions()),
            "notifications" to permissions.status(PermissionGate.notificationPermissions()),
            "storage" to permissions.status(PermissionGate.storagePermissions()),
            "bluetooth" to when {
                bluetoothAdapter == null -> "unsupported"
                bluetoothAdapter?.isEnabled == true -> "on"
                else -> "off"
            },
            "wifi" to if (isWifiEnabled()) "on" else "off",
            "location" to when {
                !locationNeeded -> "not_needed"
                isLocationEnabled() -> "on"
                else -> "off"
            },
            "nfc" to when {
                nfc == null -> "unsupported"
                nfc.isEnabled -> "on"
                else -> "off"
            },
            "battery" to when {
                power == null -> "unsupported"
                power.isIgnoringBatteryOptimizations(activity.packageName) -> "on"
                else -> "off"
            },
        )
    }

    /**
     * Opens a link from a received card: the dialer (no call is placed and
     * no permission is needed), a new email, or the browser. Only these
     * schemes are allowed, since the card came from another phone.
     */
    private fun openUri(raw: String): Boolean {
        val uri = Uri.parse(raw)
        val intent = when (uri.scheme?.lowercase()) {
            "tel" -> Intent(Intent.ACTION_DIAL, uri)
            "mailto" -> Intent(Intent.ACTION_SENDTO, uri)
            "http", "https" -> Intent(Intent.ACTION_VIEW, uri)
                .addCategory(Intent.CATEGORY_BROWSABLE)
            else -> return false
        }
        return try {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            activity.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    /** Opens the exact system page for [page]; falls back to the app's page. */
    private fun openSettingsPage(page: String): Boolean {
        val packageUri = Uri.fromParts("package", activity.packageName, null)
        val candidates = mutableListOf<Intent>()
        when (page) {
            "notifications" -> {
                candidates += Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
            }
            "bluetooth" -> candidates += Intent(Settings.ACTION_BLUETOOTH_SETTINGS)
            "wifi" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    candidates += Intent(Settings.Panel.ACTION_WIFI)
                }
                candidates += Intent(Settings.ACTION_WIFI_SETTINGS)
            }
            "location" -> candidates += Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
            "nfc" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    candidates += Intent(Settings.Panel.ACTION_NFC)
                }
                candidates += Intent(Settings.ACTION_NFC_SETTINGS)
                candidates += Intent(Settings.ACTION_WIRELESS_SETTINGS)
            }
            // The list of apps and their battery use; asking to be exempted
            // directly needs a Play-restricted permission.
            "battery" -> candidates += Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        }
        candidates += Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).setData(packageUri)
        for (intent in candidates) {
            try {
                // No resolveActivity check: package visibility (Android 11+)
                // can hide Settings pages from it even though they open.
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                activity.startActivity(intent)
                return true
            } catch (_: Exception) {
                // Some OEM builds remove pages; try the next one.
            }
        }
        return false
    }

    private fun requestEnableBluetooth(result: MethodChannel.Result) {
        if (bluetoothAdapter?.isEnabled == true) {
            result.success(true)
            return
        }

        // On Android 12+, starting ACTION_REQUEST_ENABLE without BLUETOOTH_CONNECT permission
        // throws SecurityException
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (ContextCompat.checkSelfPermission(
                    activity,
                    Manifest.permission.BLUETOOTH_CONNECT
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                result.error("PERMISSION_DENIED", "BLUETOOTH_CONNECT permission required to enable Bluetooth", null)
                return
            }
        }

        if (pendingEnableBtResult != null) {
            result.error("ALREADY_REQUESTING", "Bluetooth enable request already in progress", null)
            return
        }

        pendingEnableBtResult = result
        try {
            activity.startActivityForResult(
                Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE),
                REQUEST_CODE_ENABLE_BLUETOOTH
            )
        } catch (e: Exception) {
            pendingEnableBtResult = null
            result.error("ENABLE_BT_FAILED", e.message, null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == REQUEST_CODE_ENABLE_BLUETOOTH) {
            val res = pendingEnableBtResult ?: return false
            pendingEnableBtResult = null
            res.success(bluetoothAdapter?.isEnabled == true)
            return true
        }
        return false
    }

    private fun isWifiEnabled(): Boolean {
        val wifiMgr = activity.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        return wifiMgr?.isWifiEnabled == true
    }

    private fun isLocationEnabled(): Boolean {
        val locMgr = activity.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            locMgr.isLocationEnabled
        } else {
            locMgr.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                    locMgr.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        }
    }

    private fun isLanAvailable(): Boolean {
        try {
            // Check ConnectivityManager active network has Wi-Fi or Ethernet
            val connMgr = activity.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            if (connMgr != null) {
                val activeNet = connMgr.activeNetwork
                val caps = connMgr.getNetworkCapabilities(activeNet)
                if (caps != null && (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET))) {
                    return true
                }
            }

            // Fallback for links ConnectivityManager does not report as active: a Wi-Fi
            // network without internet (Android keeps mobile data as the default), a
            // hotspot this phone hosts, or USB tethering. Only local-link interfaces
            // count; cellular (rmnet, ccmni, ...) addresses cannot reach LAN peers.
            val interfaces = NetworkInterface.getNetworkInterfaces() ?: return false
            for (iface in interfaces) {
                if (iface.isUp && !iface.isLoopback && isLocalLinkInterface(iface.name)) {
                    for (addr in iface.inetAddresses) {
                        if (addr is Inet4Address && !addr.isLoopbackAddress && !addr.isAnyLocalAddress) {
                            return true
                        }
                    }
                }
            }
        } catch (_: Exception) {}
        return false
    }

    private fun isLocalLinkInterface(name: String): Boolean {
        val lower = name.lowercase()
        return listOf("wlan", "swlan", "ap", "softap", "eth", "rndis", "usb", "p2p").any {
            lower.startsWith(it)
        }
    }

    private fun openFileWithIntent(filePath: String, mimeType: String, result: MethodChannel.Result) {
        try {
            val file = File(filePath)
            if (!file.exists()) {
                result.error("FILE_NOT_FOUND", "File does not exist: $filePath", null)
                return
            }

            val contentUri = FileProvider.getUriForFile(
                activity,
                "${activity.packageName}.fileprovider",
                file
            )

            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(contentUri, mimeType)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }

            activity.startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("OPEN_FILE_FAILED", "Failed to open file: ${e.message}", null)
        }
    }

    private fun acquireMulticastLock() {
        try {
            if (multicastLock == null) {
                val wifiMgr = activity.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                multicastLock = wifiMgr?.createMulticastLock("vayu_multicast_lock")?.apply {
                    setReferenceCounted(true)
                }
            }
            if (multicastLock?.isHeld != true) {
                multicastLock?.acquire()
            }
        } catch (_: Exception) {}

        try {
            if (wifiLock == null) {
                val wifiMgr = activity.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                wifiLock = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    wifiMgr?.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "vayu_wifi_lock")
                } else {
                    wifiMgr?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "vayu_wifi_lock")
                }?.apply {
                    setReferenceCounted(true)
                }
            }
            if (wifiLock?.isHeld != true) {
                wifiLock?.acquire()
            }
        } catch (_: Exception) {}
    }

    private fun releaseMulticastLock() {
        try {
            if (multicastLock?.isHeld == true) {
                multicastLock?.release()
            }
        } catch (_: Exception) {}
        try {
            if (wifiLock?.isHeld == true) {
                wifiLock?.release()
            }
        } catch (_: Exception) {}
    }
}
