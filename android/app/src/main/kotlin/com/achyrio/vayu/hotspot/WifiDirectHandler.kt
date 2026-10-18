package com.achyrio.vayu.hotspot

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.wifi.WifiManager
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pGroup
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.achyrio.vayu.platform.PermissionGate
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.NetworkInterface
import java.security.SecureRandom

/**
 * Phone-to-phone Wi-Fi Direct (Android 10+), the fast path between two phones.
 *
 * Unlike a shared router, where every byte crosses the air twice, the phones
 * talk to each other directly, on 5 GHz when the hardware allows. Both phones
 * usually stay on their normal Wi-Fi meanwhile.
 *
 * Host (the receiving phone): creates a group with a random name and
 * passphrase, which travel in the Receive code like hotspot credentials.
 * Joiner: connects with those credentials, which on Android 10+ needs no
 * invitation dialog. A group also accepts plain Wi-Fi clients, so phones that
 * cannot use Wi-Fi Direct join it the way they join a hotspot.
 */
class WifiDirectHandler(
    private val activity: Activity,
    private val permissions: PermissionGate,
) : MethodChannel.MethodCallHandler {
    companion object {
        private const val TAG = "Vayu.WifiDirect"
        private const val CHANNEL = "com.achyrio.vayu/wifi_direct"
        private const val JOIN_TIMEOUT_MS = 20_000L
        private const val POLL_MS = 400L

        // Android always gives a group owner this address.
        private const val DEFAULT_OWNER_ADDRESS = "192.168.49.1"
        private const val ALPHABET = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    }

    private val main = Handler(Looper.getMainLooper())
    private val random = SecureRandom()
    private val context get() = activity.applicationContext
    private val wifi get() = context.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val manager: WifiP2pManager? by lazy {
        context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
    }

    private var channel: MethodChannel? = null
    private var p2pChannel: WifiP2pManager.Channel? = null
    private var hosting = false
    private var joined = false
    private var joinPoll: Runnable? = null

    fun register(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    fun unregister() {
        channel?.setMethodCallHandler(null)
        channel = null
        stopHosting()
        leave()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" -> result.success(isSupported())
            // Whether this phone can use a 5 GHz group (2.4 GHz-only phones
            // cannot even see one).
            "supports5Ghz" -> result.success(isSupported() && supports5Ghz())
            "createGroup" -> {
                val allow5Ghz = call.argument<Boolean>("allow5Ghz") ?: true
                withPermission(result) { createGroup(result, allow5Ghz) }
            }
            "removeGroup" -> {
                stopHosting()
                result.success(true)
            }
            "connect" -> {
                val name = call.argument<String>("networkName")
                val passphrase = call.argument<String>("passphrase")
                if (name.isNullOrEmpty() || passphrase.isNullOrEmpty()) {
                    result.error("INVALID_ARGS", "networkName and passphrase required", null)
                    return
                }
                withPermission(result) { connect(name, passphrase, result) }
            }
            "disconnect" -> {
                leave()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    /** Group creation with chosen credentials (the no-dialog path) needs Android 10. */
    private fun isSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            context.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT) &&
            manager != null

    private fun p2p(): WifiP2pManager.Channel? {
        val m = manager ?: return null
        return p2pChannel ?: m.initialize(context, Looper.getMainLooper()) {
            // The framework dropped the channel (Wi-Fi restarted); make a new one next time.
            p2pChannel = null
            hosting = false
            joined = false
        }.also { p2pChannel = it }
    }

    // ------------------------------------------------------------ permissions

    private fun withPermission(result: MethodChannel.Result, action: () -> Unit) {
        if (!isSupported()) {
            result.error("UNSUPPORTED", "Wi-Fi Direct needs Android 10 or later", null)
            return
        }
        if (!wifi.isWifiEnabled) {
            result.error("WIFI_OFF", "Wi-Fi is off", null)
            return
        }
        permissions.request(PermissionGate.directWifiPermissions()) { status ->
            if (status != PermissionGate.GRANTED) {
                result.error("PERMISSION_DENIED", "Nearby Wi-Fi permission: $status", null)
                return@request
            }
            // Before Android 13 Wi-Fi Direct requires location services to be on.
            // (isSupported already limits this to Android 10+.)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
                Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU
            ) {
                val lm = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
                if (!lm.isLocationEnabled) {
                    result.error("LOCATION_OFF", "Location services must be on for Wi-Fi Direct", null)
                    return@request
                }
            }
            action()
        }
    }

    // ---------------------------------------------------------------- hosting

    @Suppress("DEPRECATION")
    private fun supports5Ghz(): Boolean = wifi.is5GHzBandSupported

    /**
     * Hosts a group. [allow5Ghz] false when the joining phone has no 5 GHz:
     * the group is then made on 2.4 GHz, and a 5 GHz group already up is
     * replaced.
     */
    @SuppressLint("MissingPermission")
    private fun createGroup(result: MethodChannel.Result, allow5Ghz: Boolean) {
        val m = manager
        val ch = p2p()
        if (m == null || ch == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("UNSUPPORTED", "Wi-Fi Direct unavailable", null)
            return
        }
        if (hosting) {
            if (allow5Ghz) {
                describeGroup(m, ch, result, attempt = 0)
                return
            }
            m.requestGroupInfo(ch) { group ->
                if (group != null && group.frequency >= 4900) {
                    Log.i(TAG, "Replacing the 5 GHz group for a 2.4 GHz-only phone")
                    hosting = false
                    m.removeGroup(ch, object : WifiP2pManager.ActionListener {
                        override fun onSuccess() = startGroup(m, ch, result, allow5Ghz)
                        override fun onFailure(reason: Int) = startGroup(m, ch, result, allow5Ghz)
                    })
                } else {
                    describeGroup(m, ch, result, attempt = 0)
                }
            }
            return
        }
        // A group left by an earlier screen (or another app) blocks creating one.
        m.removeGroup(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() = startGroup(m, ch, result, allow5Ghz)
            override fun onFailure(reason: Int) = startGroup(m, ch, result, allow5Ghz)
        })
    }

    @SuppressLint("MissingPermission")
    private fun startGroup(
        m: WifiP2pManager,
        ch: WifiP2pManager.Channel,
        result: MethodChannel.Result,
        allow5Ghz: Boolean,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        // 5 GHz is several times faster than 2.4 GHz; fall back when the phone
        // cannot host there (no 5 GHz, or its radio is tied to a 2.4 GHz router).
        // A 2.4 GHz-only joiner gets a 2.4 GHz group.
        val bands = when {
            !allow5Ghz -> listOf(
                WifiP2pConfig.GROUP_OWNER_BAND_2GHZ,
                WifiP2pConfig.GROUP_OWNER_BAND_AUTO,
            )
            supports5Ghz() -> listOf(
                WifiP2pConfig.GROUP_OWNER_BAND_5GHZ,
                WifiP2pConfig.GROUP_OWNER_BAND_AUTO,
            )
            else -> listOf(WifiP2pConfig.GROUP_OWNER_BAND_AUTO)
        }
        tryCreate(m, ch, bands, 0, result)
    }

    @SuppressLint("MissingPermission")
    private fun tryCreate(
        m: WifiP2pManager,
        ch: WifiP2pManager.Channel,
        bands: List<Int>,
        index: Int,
        result: MethodChannel.Result,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val config = WifiP2pConfig.Builder()
            .setNetworkName("DIRECT-vy-${randomText(6)}")
            .setPassphrase(randomText(16))
            .setGroupOperatingBand(bands[index])
            .enablePersistentMode(false)
            .build()
        try {
            m.createGroup(ch, config, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    hosting = true
                    Log.i(TAG, "Group created (band ${bands[index]})")
                    describeGroup(m, ch, result, attempt = 0)
                }

                override fun onFailure(reason: Int) {
                    if (index + 1 < bands.size) {
                        tryCreate(m, ch, bands, index + 1, result)
                    } else {
                        result.error(failureCode(reason), "Could not create the group ($reason)", null)
                    }
                }
            })
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message, null)
        }
    }

    /** Reports the group once its network name and this phone's address exist. */
    @SuppressLint("MissingPermission")
    private fun describeGroup(
        m: WifiP2pManager,
        ch: WifiP2pManager.Channel,
        result: MethodChannel.Result,
        attempt: Int,
    ) {
        try {
            m.requestGroupInfo(ch) { group ->
                val address = group?.let { ownerAddress(it) }
                if (group != null && group.isGroupOwner && group.passphrase != null &&
                    (address != null || attempt >= 10)
                ) {
                    result.success(
                        mapOf(
                            "networkName" to group.networkName,
                            "passphrase" to group.passphrase,
                            "hostAddress" to (address ?: DEFAULT_OWNER_ADDRESS),
                            "frequencyMhz" to
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) group.frequency else 0,
                        )
                    )
                } else if (attempt < 15) {
                    // The group interface takes a moment to come up.
                    main.postDelayed({ describeGroup(m, ch, result, attempt + 1) }, POLL_MS)
                } else {
                    stopHosting()
                    result.error("FAILED", "The group did not come up", null)
                }
            }
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message, null)
        }
    }

    private fun ownerAddress(group: WifiP2pGroup): String? {
        val name = group.`interface` ?: return null
        return try {
            NetworkInterface.getByName(name)?.inetAddresses?.toList()
                ?.firstOrNull { it is Inet4Address && !it.isLoopbackAddress }
                ?.hostAddress
        } catch (_: Exception) {
            null
        }
    }

    private fun stopHosting() {
        if (!hosting) return
        hosting = false
        val ch = p2pChannel ?: return
        try {
            manager?.removeGroup(ch, null)
        } catch (_: Exception) {}
    }

    // ---------------------------------------------------------------- joining

    @SuppressLint("MissingPermission")
    private fun connect(networkName: String, passphrase: String, result: MethodChannel.Result) {
        val m = manager
        val ch = p2p()
        if (m == null || ch == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("UNSUPPORTED", "Wi-Fi Direct unavailable", null)
            return
        }
        leave()
        var answered = false
        val deadline = System.currentTimeMillis() + JOIN_TIMEOUT_MS
        fun finish(ownerAddress: String?) {
            if (answered) return
            answered = true
            joinPoll?.let { main.removeCallbacks(it) }
            joinPoll = null
            if (ownerAddress == null) {
                leave()
                main.post { result.success(null) }
            } else {
                joined = true
                main.post { result.success(mapOf("groupOwnerAddress" to ownerAddress)) }
            }
        }

        val poll = object : Runnable {
            override fun run() {
                if (answered) return
                m.requestConnectionInfo(ch) { info ->
                    val owner = info?.groupOwnerAddress?.hostAddress
                    when {
                        info != null && info.groupFormed && !info.isGroupOwner && owner != null ->
                            finish(owner)
                        System.currentTimeMillis() > deadline -> finish(null)
                        else -> main.postDelayed(this, POLL_MS)
                    }
                }
            }
        }

        val config = WifiP2pConfig.Builder()
            .setNetworkName(networkName)
            .setPassphrase(passphrase)
            .enablePersistentMode(false)
            .build()
        try {
            m.connect(ch, config, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    joinPoll = poll
                    main.postDelayed(poll, POLL_MS)
                }

                override fun onFailure(reason: Int) {
                    Log.w(TAG, "connect failed ($reason)")
                    finish(null)
                }
            })
        } catch (e: SecurityException) {
            answered = true
            result.error("PERMISSION_DENIED", e.message, null)
        }
    }

    private fun leave() {
        joinPoll?.let { main.removeCallbacks(it) }
        joinPoll = null
        val ch = p2pChannel ?: return
        val m = manager ?: return
        try {
            m.cancelConnect(ch, null)
        } catch (_: Exception) {}
        if (joined) {
            joined = false
            // As a client, removing the group just disconnects this phone.
            try {
                m.removeGroup(ch, null)
            } catch (_: Exception) {}
        }
    }

    private fun failureCode(reason: Int): String = when (reason) {
        WifiP2pManager.P2P_UNSUPPORTED -> "UNSUPPORTED"
        WifiP2pManager.BUSY -> "BUSY"
        else -> "FAILED"
    }

    private fun randomText(length: Int): String =
        buildString(length) { repeat(length) { append(ALPHABET[random.nextInt(ALPHABET.length)]) } }
}
