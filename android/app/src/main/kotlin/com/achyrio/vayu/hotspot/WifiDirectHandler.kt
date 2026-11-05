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
import java.util.concurrent.atomic.AtomicBoolean

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
    private class GuardedResult(private val target: MethodChannel.Result) : MethodChannel.Result {
        private val completed = AtomicBoolean(false)
        val isActive: Boolean get() = !completed.get()
        fun claim(): Boolean = completed.compareAndSet(false, true)
        override fun success(result: Any?) {
            if (claim()) target.success(result)
        }
        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            if (claim()) target.error(errorCode, errorMessage, errorDetails)
        }
        override fun notImplemented() {
            if (claim()) target.notImplemented()
        }
    }
    companion object {
        private const val TAG = "Vayu.WifiDirect"
        private const val CHANNEL = "com.achyrio.vayu/wifi_direct"
        // Finding the group, forming it and DHCP; 5 GHz scans take longest.
        private const val JOIN_TIMEOUT_MS = 30_000L
        private const val POLL_MS = 400L
        private const val CONNECT_RETRIES = 3
        private const val RETRY_MS = 1_500L
        private const val SETTLE_MS = 500L

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

    // Answers the join still waiting when a newer join or a leave replaces
    // it; that caller used to wait forever.
    private var supersedeJoin: (() -> Unit)? = null

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
                withPermission(result) {
                    val guarded = guardedResult(result, 25_000L, "Group creation timed out")
                    createGroup(guarded, allow5Ghz)
                }
            }
            "removeGroup" -> {
                stopHosting()
                result.success(true)
            }
            "connect" -> {
                val name = call.argument<String>("networkName")
                val passphrase = call.argument<String>("passphrase")
                val nameBytes = name?.toByteArray(Charsets.UTF_8)?.size ?: 0
                val passwordLength = passphrase?.length ?: 0
                val passwordPrintableAscii = passphrase?.all { it.code in 0x20..0x7e } == true
                if (name == null || passphrase == null || nameBytes !in 1..32 ||
                    passwordLength !in 8..63 || !passwordPrintableAscii) {
                    Log.e(
                        TAG,
                        "stage=join_validation_failed ssidBytes=$nameBytes " +
                            "passphraseLength=$passwordLength",
                    )
                    result.error(
                        "INVALID_CREDENTIALS",
                        "Wi-Fi Direct credentials have invalid lengths",
                        null,
                    )
                    return
                }
                Log.i(
                    TAG,
                    "stage=join_credentials_received ssidBytes=$nameBytes " +
                        "passphraseLength=$passwordLength",
                )
                withPermission(result) {
                    val guarded = guardedResult(result, 42_000L, "Joining the Wi-Fi Direct group timed out")
                    connect(name, passphrase, guarded)
                }
            }
            "disconnect" -> {
                leave()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    /** Android/OEM P2P callbacks can be lost; never leave Flutter waiting forever. */
    private fun guardedResult(
        target: MethodChannel.Result,
        timeoutMs: Long,
        timeoutMessage: String,
    ): GuardedResult {
        val guarded = GuardedResult(target)
        val timeout = Runnable {
            if (!guarded.claim()) return@Runnable
            Log.e(TAG, "stage=platform_callback_timeout timeoutMs=$timeoutMs")
            joinPoll?.let { main.removeCallbacks(it) }
            joinPoll = null
            supersedeJoin = null
            joined = false
            hosting = false
            val ch = p2pChannel
            if (ch != null) try {
                manager?.cancelConnect(ch, null)
                manager?.removeGroup(ch, null)
            } catch (_: Exception) {}
            target.error("P2P_TIMEOUT", timeoutMessage, null)
        }
        main.postDelayed(timeout, timeoutMs)
        return guarded
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
            Log.e(TAG, "stage=preflight_failed reason=wifi_direct_unsupported")
            result.error("UNSUPPORTED", "Wi-Fi Direct needs Android 10 or later", null)
            return
        }
        if (!wifi.isWifiEnabled) {
            Log.e(TAG, "stage=preflight_failed reason=wifi_disabled")
            result.error("WIFI_OFF", "Wi-Fi is off", null)
            return
        }
        permissions.request(PermissionGate.directWifiPermissions()) { status ->
            if (status != PermissionGate.GRANTED) {
                Log.e(TAG, "stage=preflight_failed reason=permission status=$status")
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
                    Log.e(TAG, "stage=preflight_failed reason=location_services_disabled")
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
    private fun createGroup(result: GuardedResult, allow5Ghz: Boolean) {
        val m = manager
        val ch = p2p()
        if (m == null || ch == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("UNSUPPORTED", "Wi-Fi Direct unavailable", null)
            return
        }
        if (!result.isActive) return
        if (hosting) {
            if (allow5Ghz) {
                describeGroup(m, ch, result, attempt = 0)
                return
            }
            m.requestGroupInfo(ch) { group ->
                if (!result.isActive) return@requestGroupInfo
                if (group != null && group.frequency >= 4900) {
                    Log.i(TAG, "Replacing the 5 GHz group for a 2.4 GHz-only phone")
                    hosting = false
                    m.removeGroup(ch, object : WifiP2pManager.ActionListener {
                        override fun onSuccess() { if (result.isActive) startGroup(m, ch, result, allow5Ghz) }
                        override fun onFailure(reason: Int) { if (result.isActive) startGroup(m, ch, result, allow5Ghz) }
                    })
                } else {
                    describeGroup(m, ch, result, attempt = 0)
                }
            }
            return
        }
        // A group left by an earlier screen (or another app) blocks creating one.
        m.removeGroup(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() { if (result.isActive) startGroup(m, ch, result, allow5Ghz) }
            override fun onFailure(reason: Int) { if (result.isActive) startGroup(m, ch, result, allow5Ghz) }
        })
    }

    @SuppressLint("MissingPermission")
    private fun startGroup(
        m: WifiP2pManager,
        ch: WifiP2pManager.Channel,
        result: GuardedResult,
        allow5Ghz: Boolean,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || !result.isActive) return
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
        result: GuardedResult,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || !result.isActive) return
        val networkName = "DIRECT-vy-${randomText(6)}"
        val passphrase = randomText(16)
        val config = WifiP2pConfig.Builder()
            .setNetworkName(networkName)
            .setPassphrase(passphrase)
            .setGroupOperatingBand(bands[index])
            .enablePersistentMode(false)
            .build()
        Log.i(
            TAG,
            "stage=group_create_start band=${bands[index]} " +
                "ssidBytes=${networkName.toByteArray(Charsets.UTF_8).size} " +
                "passphraseLength=${passphrase.length}",
        )
        if (!result.isActive) return
        try {
            m.createGroup(ch, config, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    if (!result.isActive) {
                        hosting = false
                        m.removeGroup(ch, null)
                        return
                    }
                    hosting = true
                    Log.i(TAG, "stage=group_create_accepted band=${bands[index]}")
                    // Some radios accept a 5 GHz group they cannot bring up
                    // (Wi-Fi busy on another channel); then try the next band.
                    val nextBand = if (index + 1 < bands.size) {
                        { tryCreate(m, ch, bands, index + 1, result) }
                    } else {
                        null
                    }
                    describeGroup(m, ch, result, attempt = 0, fallback = nextBand)
                }

                override fun onFailure(reason: Int) {
                    if (!result.isActive) return
                    if (index + 1 < bands.size) {
                        Log.w(
                            TAG,
                            "stage=group_create_failed reason=$reason; " +
                                "retryBand=${bands[index + 1]}",
                        )
                        tryCreate(m, ch, bands, index + 1, result)
                    } else {
                        Log.e(TAG, "stage=group_create_failed reason=$reason")
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
        result: GuardedResult,
        attempt: Int,
        fallback: (() -> Unit)? = null,
    ) {
        if (!result.isActive) return
        try {
            m.requestGroupInfo(ch) { group ->
                if (!result.isActive) {
                    if (group?.isGroupOwner == true) {
                        hosting = false
                        m.removeGroup(ch, null)
                    }
                    return@requestGroupInfo
                }
                val address = group?.let { ownerAddress(it) }
                val ssidBytes = group?.networkName?.toByteArray(Charsets.UTF_8)?.size ?: 0
                val groupPassphrase = group?.passphrase
                val passwordLength = groupPassphrase?.length ?: 0
                val passwordPrintableAscii =
                    groupPassphrase?.all { it.code in 0x20..0x7e } == true
                val credentialsValid = ssidBytes in 1..32 &&
                    passwordLength in 8..63 && passwordPrintableAscii
                val frequencyMhz = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    group?.frequency ?: 0
                } else {
                    0
                }
                if (group != null && group.isGroupOwner && credentialsValid &&
                    (address != null || attempt >= 10)) {
                    Log.i(
                        TAG,
                        "stage=group_ready ssidBytes=$ssidBytes " +
                            "passphraseLength=$passwordLength " +
                            "ownerAddressPresent=${address != null} frequencyMhz=$frequencyMhz",
                    )
                    result.success(
                        mapOf(
                            "networkName" to group.networkName,
                            "passphrase" to group.passphrase,
                            "hostAddress" to (address ?: DEFAULT_OWNER_ADDRESS),
                            "frequencyMhz" to frequencyMhz,
                        )
                    )
                } else if (attempt < 15) {
                    // The group interface takes a moment to come up.
                    main.postDelayed({ describeGroup(m, ch, result, attempt + 1, fallback) }, POLL_MS)
                } else if (fallback != null) {
                    Log.w(TAG, "stage=group_ready_failed; retrying on the next band")
                    hosting = false
                    m.removeGroup(ch, object : WifiP2pManager.ActionListener {
                        override fun onSuccess() = fallback()
                        override fun onFailure(reason: Int) = fallback()
                    })
                } else {
                    stopHosting()
                    val reason = if (group?.isGroupOwner == true && !credentialsValid) {
                        "The group returned invalid credential lengths"
                    } else {
                        "The group did not come up"
                    }
                    Log.e(
                        TAG,
                        "stage=group_ready_failed ssidBytes=$ssidBytes " +
                            "passphraseLength=$passwordLength " +
                            "ownerAddressPresent=${address != null}",
                    )
                    result.error("FAILED", reason, null)
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

    /**
     * Joins a group and answers with the owner's address only once this phone
     * has its own address in the group. "Group formed" comes before DHCP
     * finishes; connecting then failed at once, and Vayu gave up on the group.
     */
    @SuppressLint("MissingPermission")
    private fun connect(networkName: String, passphrase: String, result: GuardedResult) {
        val m = manager
        val ch = p2p()
        if (m == null || ch == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("UNSUPPORTED", "Wi-Fi Direct unavailable", null)
            return
        }
        supersedeJoin?.invoke()
        joinPoll?.let { main.removeCallbacks(it) }
        joinPoll = null
        var answered = false
        supersedeJoin = {
            if (!answered) {
                answered = true
                main.post { result.error("SUPERSEDED", "Replaced by a newer join", null) }
            }
        }
        val deadline = System.currentTimeMillis() + JOIN_TIMEOUT_MS
        fun finish(ownerAddress: String?, localAddress: String?, why: String) {
            if (answered) return
            answered = true
            supersedeJoin = null
            joinPoll?.let { main.removeCallbacks(it) }
            joinPoll = null
            if (ownerAddress == null) {
                Log.e(TAG, "stage=group_join_failed reason=$why")
                joined = true // whatever half-formed group exists is left
                leave()
                main.post { result.error("JOIN_FAILED", why, null) }
            } else {
                Log.i(
                    TAG,
                    "stage=group_joined ownerAddress=$ownerAddress localAddress=$localAddress",
                )
                joined = true
                main.post {
                    result.success(
                        mapOf("groupOwnerAddress" to ownerAddress, "localAddress" to localAddress),
                    )
                }
            }
        }

        val poll = object : Runnable {
            override fun run() {
                if (answered || !result.isActive) return
                m.requestConnectionInfo(ch) { info ->
                    if (answered || !result.isActive) return@requestConnectionInfo
                    val owner = info?.groupOwnerAddress?.hostAddress
                    if (info != null && info.groupFormed && !info.isGroupOwner && owner != null) {
                        m.requestGroupInfo(ch) { group ->
                            if (answered || !result.isActive) return@requestGroupInfo
                            val local = group?.let { ownerAddress(it) } ?: p2pClientAddress()
                            when {
                                local != null -> finish(owner, local, "own address $local")
                                System.currentTimeMillis() > deadline ->
                                    finish(null, null, "no address in the group")
                                else -> main.postDelayed(this, POLL_MS)
                            }
                        }
                    } else if (System.currentTimeMillis() > deadline) {
                        finish(null, null, "group not formed in time")
                    } else {
                        main.postDelayed(this, POLL_MS)
                    }
                }
            }
        }

        val config = WifiP2pConfig.Builder()
            .setNetworkName(networkName)
            .setPassphrase(passphrase)
            .enablePersistentMode(false)
            .build()

        fun attempt(left: Int) {
            if (answered || !result.isActive) return
            try {
                m.connect(ch, config, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        if (answered || !result.isActive) return
                        Log.i(TAG, "stage=group_connect_request_accepted retriesRemaining=$left")
                        joinPoll = poll
                        main.postDelayed(poll, POLL_MS)
                    }

                    override fun onFailure(reason: Int) {
                        if (answered || !result.isActive) return
                        // BUSY right after leaving a group or while a scan
                        // runs is common and passes within a second or two.
                        if (left > 0 && reason != WifiP2pManager.P2P_UNSUPPORTED) {
                            Log.w(
                                TAG,
                                "stage=group_connect_request_refused reason=$reason " +
                                    "retriesRemaining=$left",
                            )
                            main.postDelayed({ attempt(left - 1) }, RETRY_MS)
                        } else {
                            Log.e(TAG, "stage=group_connect_request_failed reason=$reason")
                            finish(null, null, "connect refused ($reason)")
                        }
                    }
                })
            } catch (e: SecurityException) {
                answered = true
                result.error("PERMISSION_DENIED", e.message, null)
            }
        }

        // One phone is in one group at a time: a group this phone hosts, a
        // half-joined one from an earlier try, or a peer scan block joining.
        stopHosting()
        try {
            m.stopPeerDiscovery(ch, null)
            m.cancelConnect(ch, null)
        } catch (_: Exception) {}
        m.removeGroup(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() { if (result.isActive) main.postDelayed({ attempt(CONNECT_RETRIES) }, SETTLE_MS) }
            override fun onFailure(reason: Int) { if (result.isActive) attempt(CONNECT_RETRIES) }
        })
    }

    /** This phone's IPv4 address on a Wi-Fi Direct interface, if it has one. */
    private fun p2pClientAddress(): String? = try {
        NetworkInterface.getNetworkInterfaces()?.toList()
            ?.filter { it.isUp && it.name.startsWith("p2p") }
            ?.flatMap { it.inetAddresses.toList() }
            ?.firstOrNull { it is Inet4Address && !it.isLoopbackAddress }
            ?.hostAddress
    } catch (_: Exception) {
        null
    }

    private fun leave() {
        supersedeJoin?.invoke()
        supersedeJoin = null
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
