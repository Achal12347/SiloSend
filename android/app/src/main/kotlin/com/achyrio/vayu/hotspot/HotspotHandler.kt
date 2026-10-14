package com.achyrio.vayu.hotspot

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiConfiguration
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * Phone-to-phone Wi-Fi without a router.
 *
 * Host: Android LocalOnlyHotspot (API 26+): no internet, no tethering, random
 * WPA2 credentials, kept only while Vayu holds the reservation.
 * Joiner: Android 10+ uses WifiNetworkSpecifier (the system asks the user to
 * confirm); Android 8-9 add the network the legacy way. In both cases the app
 * process is bound to that network, because a network without internet would
 * otherwise never become the default and sockets would go out over cellular.
 */
class HotspotHandler(private val activity: Activity) : MethodChannel.MethodCallHandler {
    companion object {
        private const val TAG = "Vayu.Hotspot"
        private const val CHANNEL = "com.achyrio.vayu/hotspot"
        private const val REQUEST_CODE = 4104
        private const val JOIN_TIMEOUT_MS = 30_000
    }

    private val main = Handler(Looper.getMainLooper())
    private val wifi get() = activity.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val connectivity get() =
        activity.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private var channel: MethodChannel? = null
    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var pendingAfterPermission: (() -> Unit)? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var joinCallback: ConnectivityManager.NetworkCallback? = null
    private var legacyNetworkId: Int? = null

    fun register(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    fun unregister() {
        channel?.setMethodCallHandler(null)
        channel = null
        stopHotspot()
        leave()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> withHotspotPermission(result) { startHotspot(result) }
            "stop" -> {
                stopHotspot()
                result.success(true)
            }
            "join" -> {
                val ssid = call.argument<String>("ssid")
                val passphrase = call.argument<String>("passphrase") ?: ""
                if (ssid.isNullOrEmpty()) {
                    result.error("INVALID_ARGS", "ssid required", null)
                    return
                }
                withHotspotPermission(result) { join(ssid, passphrase, result) }
            }
            "leave" -> {
                leave()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------ permissions

    private fun requiredPermissions(): List<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            listOf(Manifest.permission.NEARBY_WIFI_DEVICES)
        } else {
            listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun withHotspotPermission(result: MethodChannel.Result, action: () -> Unit) {
        val missing = requiredPermissions().filter {
            ContextCompat.checkSelfPermission(activity, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            checkLocationThen(result, action)
            return
        }
        if (pendingPermissionResult != null) {
            result.error("ALREADY_REQUESTING", "Permission request in progress", null)
            return
        }
        pendingPermissionResult = result
        pendingAfterPermission = action
        ActivityCompat.requestPermissions(activity, missing.toTypedArray(), REQUEST_CODE)
    }

    // Before Android 13 the hotspot API requires location services to be on.
    private fun checkLocationThen(result: MethodChannel.Result, action: () -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            val lm = activity.getSystemService(Context.LOCATION_SERVICE) as LocationManager
            val on = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                lm.isLocationEnabled
            } else {
                lm.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                    lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
            }
            if (!on) {
                result.error("LOCATION_OFF", "Location services must be on for phone-to-phone Wi-Fi", null)
                return
            }
        }
        action()
    }

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pendingPermissionResult ?: return true
        val action = pendingAfterPermission
        pendingPermissionResult = null
        pendingAfterPermission = null
        if (grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }) {
            if (action != null) checkLocationThen(result, action)
        } else {
            result.error("PERMISSION_DENIED", "Nearby Wi-Fi permission denied", null)
        }
        return true
    }

    // -------------------------------------------------------------- hosting

    @Suppress("DEPRECATION", "MissingPermission")
    private fun startHotspot(result: MethodChannel.Result) {
        reservation?.let {
            result.success(describe(it))
            return
        }
        try {
            wifi.startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
                override fun onStarted(res: WifiManager.LocalOnlyHotspotReservation) {
                    reservation = res
                    // The soft-AP interface can take a moment to get its address.
                    main.postDelayed({ result.success(describe(res)) }, 600)
                }

                override fun onStopped() {
                    reservation = null
                }

                override fun onFailed(reason: Int) {
                    val code = if (reason == ERROR_INCOMPATIBLE_MODE) "INCOMPATIBLE_MODE" else "FAILED"
                    result.error(code, "LocalOnlyHotspot failed ($reason)", null)
                }
            }, main)
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message, null)
        } catch (e: IllegalStateException) {
            // Thrown when a hotspot from this app is already active.
            result.error("INCOMPATIBLE_MODE", e.message, null)
        }
    }

    @Suppress("DEPRECATION")
    private fun describe(res: WifiManager.LocalOnlyHotspotReservation): Map<String, Any?> {
        val (ssid, pass) = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val config = res.softApConfiguration
            val name = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                config.wifiSsid?.toString()?.trim('"')
            } else {
                config.ssid
            }
            name to config.passphrase
        } else {
            val config = res.wifiConfiguration
            config?.SSID?.trim('"') to config?.preSharedKey?.trim('"')
        }
        return mapOf("ssid" to ssid, "passphrase" to pass, "hostAddress" to hotspotAddress())
    }

    /** This phone's IPv4 on the soft-AP interface (names vary by vendor). */
    private fun hotspotAddress(): String? {
        val candidates = mutableListOf<Pair<Int, String>>()
        try {
            for (iface in NetworkInterface.getNetworkInterfaces()) {
                if (!iface.isUp || iface.isLoopback) continue
                val name = iface.name.lowercase()
                val rank = when {
                    name.startsWith("swlan") || name.startsWith("ap") || name.startsWith("softap") -> 0
                    name.startsWith("wlan") && name != "wlan0" -> 1
                    name == "wlan0" -> 2
                    else -> continue
                }
                for (addr in iface.inetAddresses) {
                    if (addr is Inet4Address && !addr.isLoopbackAddress && addr.isSiteLocalAddress) {
                        candidates.add(rank to (addr.hostAddress ?: continue))
                    }
                }
            }
        } catch (_: Exception) {}
        return candidates.minByOrNull { it.first }?.second
    }

    private fun stopHotspot() {
        try {
            reservation?.close()
        } catch (_: Exception) {}
        reservation = null
    }

    // -------------------------------------------------------------- joining

    private fun join(ssid: String, passphrase: String, result: MethodChannel.Result) {
        leave()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            joinWithSpecifier(ssid, passphrase, result)
        } else {
            joinLegacy(ssid, passphrase, result)
        }
    }

    private fun joinWithSpecifier(ssid: String, passphrase: String, result: MethodChannel.Result) {
        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .apply { if (passphrase.isNotEmpty()) setWpa2Passphrase(passphrase) }
            .build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()
        var answered = false
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                connectivity.bindProcessToNetwork(network)
                Log.i(TAG, "Joined peer hotspot")
                if (!answered) {
                    answered = true
                    main.post { result.success(true) }
                }
            }

            override fun onUnavailable() {
                if (!answered) {
                    answered = true
                    main.post { result.success(false) }
                }
            }

            override fun onLost(network: Network) {
                connectivity.bindProcessToNetwork(null)
            }
        }
        joinCallback = callback
        connectivity.requestNetwork(request, callback, JOIN_TIMEOUT_MS)
    }

    @Suppress("DEPRECATION", "MissingPermission")
    private fun joinLegacy(ssid: String, passphrase: String, result: MethodChannel.Result) {
        val config = WifiConfiguration().apply {
            SSID = "\"$ssid\""
            if (passphrase.isNotEmpty()) {
                preSharedKey = "\"$passphrase\""
            } else {
                allowedKeyManagement.set(WifiConfiguration.KeyMgmt.NONE)
            }
        }
        val id = wifi.addNetwork(config)
        if (id < 0 || !wifi.enableNetwork(id, true)) {
            result.success(false)
            return
        }
        legacyNetworkId = id
        val deadline = System.currentTimeMillis() + JOIN_TIMEOUT_MS
        val poll = object : Runnable {
            override fun run() {
                val wifiNetwork = connectivity.allNetworks.firstOrNull {
                    connectivity.getNetworkCapabilities(it)
                        ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
                }
                val connectedSsid = wifi.connectionInfo?.ssid?.trim('"')
                if (wifiNetwork != null && connectedSsid == ssid) {
                    connectivity.bindProcessToNetwork(wifiNetwork)
                    result.success(true)
                } else if (System.currentTimeMillis() > deadline) {
                    result.success(false)
                } else {
                    main.postDelayed(this, 500)
                }
            }
        }
        main.post(poll)
    }

    @Suppress("DEPRECATION")
    private fun leave() {
        try {
            connectivity.bindProcessToNetwork(null)
        } catch (_: Exception) {}
        joinCallback?.let {
            try {
                connectivity.unregisterNetworkCallback(it)
            } catch (_: Exception) {}
        }
        joinCallback = null
        legacyNetworkId?.let {
            try {
                wifi.removeNetwork(it)
            } catch (_: Exception) {}
        }
        legacyNetworkId = null
    }
}
