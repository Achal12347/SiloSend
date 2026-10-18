package com.achyrio.vayu.platform

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner

/**
 * Every runtime permission Vayu asks for goes through here.
 *
 * Android shows one permission dialog at a time. When two handlers asked at
 * once (nearby access during onboarding while storage or notifications were
 * also requested), Android cancelled one; the empty result was then read as
 * "permanently denied" and people were sent to Settings for no reason. The
 * gate queues requests, so a dialog is never shown over another.
 *
 * It also tells the states apart:
 * - not_requested: never answered.
 * - denied: refused (or the dialog was dismissed); asking again shows it.
 * - permanently_denied: Android will not show the dialog any more; only the
 *   app's settings page can change it.
 */
class PermissionGate(private val activity: Activity) {
    companion object {
        const val REQUEST_CODE = 4200
        private const val PREFS = "vayu_permissions"
        private const val LEGACY_PREFS = "vayu_platform_prefs"
        private const val LEGACY_KEY_NEARBY = "has_requested_nearby_permissions"

        // An answer this fast means Android refused without showing a dialog.
        private const val INSTANT_ANSWER_MS = 350L

        const val GRANTED = "granted"
        const val NOT_REQUESTED = "not_requested"
        const val DENIED = "denied"
        const val PERMANENTLY_DENIED = "permanently_denied"
        const val NOT_NEEDED = "not_needed"

        /** Bluetooth discovery and connections. */
        fun nearbyPermissions(): List<String> =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                listOf(
                    Manifest.permission.BLUETOOTH_SCAN,
                    Manifest.permission.BLUETOOTH_ADVERTISE,
                    Manifest.permission.BLUETOOTH_CONNECT,
                )
            } else {
                listOf(
                    Manifest.permission.ACCESS_FINE_LOCATION,
                    Manifest.permission.ACCESS_COARSE_LOCATION,
                )
            }

        /**
         * Phone-to-phone Wi-Fi (LocalOnlyHotspot and joining it). Android 12
         * requires asking for fine and coarse location together.
         */
        fun directWifiPermissions(): List<String> =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                listOf(Manifest.permission.NEARBY_WIFI_DEVICES)
            } else {
                listOf(
                    Manifest.permission.ACCESS_FINE_LOCATION,
                    Manifest.permission.ACCESS_COARSE_LOCATION,
                )
            }

        fun notificationPermissions(): List<String> =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                listOf(Manifest.permission.POST_NOTIFICATIONS)
            } else {
                emptyList()
            }

        /** Android 8-10 only: saving to the shared Downloads folder. */
        fun storagePermissions(): List<String> =
            if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.Q) {
                listOf(Manifest.permission.WRITE_EXTERNAL_STORAGE)
            } else {
                emptyList()
            }

        fun cameraPermissions(): List<String> = listOf(Manifest.permission.CAMERA)

        fun contactsPermissions(): List<String> = listOf(Manifest.permission.READ_CONTACTS)

        fun permissionsFor(group: String): List<String>? = when (group) {
            "nearby" -> nearbyPermissions()
            "directWifi" -> directWifiPermissions()
            "notifications" -> notificationPermissions()
            "storage" -> storagePermissions()
            "camera" -> cameraPermissions()
            "contacts" -> contactsPermissions()
            else -> null
        }
    }

    private class Request(
        val permissions: List<String>,
        val callback: (String) -> Unit,
    )

    private val queue = ArrayDeque<Request>()
    private var current: Request? = null
    private var rationaleBefore: Map<String, Boolean> = emptyMap()
    private var askedAt = 0L

    // Android only shows a dialog to a resumed activity; a request made in the
    // background waits here until the user is back.
    private var resumed = (activity as? LifecycleOwner)
        ?.lifecycle?.currentState?.isAtLeast(Lifecycle.State.RESUMED) == true
    private var pausedSinceAsk = false

    /** Called from the activity's onResume. */
    fun onResume() {
        resumed = true
        val lost = current
        if (lost != null && pausedSinceAsk) {
            // Android delivers the answer before onResume. Reaching here with
            // the request still open means the answer was dropped; without
            // this, the caller (and every later request) would wait forever.
            current = null
            pausedSinceAsk = false
            lost.callback(status(lost.permissions))
        }
        pump()
    }

    /** Called from the activity's onPause. */
    fun onPause() {
        resumed = false
        if (current != null) pausedSinceAsk = true
    }

    private val prefs get() = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun granted(permission: String) =
        ContextCompat.checkSelfPermission(activity, permission) == PackageManager.PERMISSION_GRANTED

    /** Current state of [permissions] as a whole (one of the constants above). */
    fun status(permissions: List<String>): String {
        if (permissions.isEmpty()) return NOT_NEEDED
        val missing = permissions.filter { !granted(it) }
        if (missing.isEmpty()) return GRANTED
        val prefs = prefs
        val anyPermanent = missing.any {
            prefs.getBoolean("permanent_$it", false) &&
                !ActivityCompat.shouldShowRequestPermissionRationale(activity, it)
        }
        if (anyPermanent) return PERMANENTLY_DENIED
        val anyAsked = missing.any { prefs.getBoolean("asked_$it", false) } || legacyNearbyAsked(missing)
        return if (anyAsked) DENIED else NOT_REQUESTED
    }

    // Builds before the gate kept one flag for the Bluetooth/location group.
    private fun legacyNearbyAsked(missing: List<String>): Boolean {
        if (missing.none { it in nearbyPermissions() }) return false
        return activity.getSharedPreferences(LEGACY_PREFS, Context.MODE_PRIVATE)
            .getBoolean(LEGACY_KEY_NEARBY, false)
    }

    /**
     * Shows the system dialog for whatever in [permissions] is missing (after
     * any dialog already showing) and reports the resulting [status].
     */
    fun request(permissions: List<String>, callback: (String) -> Unit) {
        if (permissions.isEmpty()) {
            callback(NOT_NEEDED)
            return
        }
        queue.addLast(Request(permissions, callback))
        pump()
    }

    /**
     * True when Android would show the explanation-worthy "denied once" state:
     * the user refused before and the dialog can still be shown.
     */
    fun rationale(permissions: List<String>): Boolean =
        permissions.any {
            !granted(it) && ActivityCompat.shouldShowRequestPermissionRationale(activity, it)
        }

    private fun pump() {
        if (current != null || !resumed) return
        while (true) {
            val next = queue.removeFirstOrNull() ?: return
            // An earlier dialog may already have granted these.
            val missing = next.permissions.filter { !granted(it) }
            if (missing.isEmpty()) {
                next.callback(GRANTED)
                continue
            }
            current = next
            pausedSinceAsk = false
            rationaleBefore = missing.associateWith {
                ActivityCompat.shouldShowRequestPermissionRationale(activity, it)
            }
            askedAt = SystemClock.elapsedRealtime()
            try {
                ActivityCompat.requestPermissions(activity, missing.toTypedArray(), REQUEST_CODE)
            } catch (_: Exception) {
                current = null
                next.callback(status(next.permissions))
                continue
            }
            return
        }
    }

    /** Called by the activity for every permission result; true when it was ours. */
    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val request = current ?: return true
        current = null
        pausedSinceAsk = false

        // Empty results mean the request was interrupted (activity paused,
        // another dialog): nothing was answered, so nothing is recorded.
        if (permissions.isNotEmpty() && grantResults.isNotEmpty()) {
            val instant = SystemClock.elapsedRealtime() - askedAt < INSTANT_ANSWER_MS
            val editor = prefs.edit()
            permissions.forEachIndexed { index, permission ->
                if (index >= grantResults.size) return@forEachIndexed
                editor.putBoolean("asked_$permission", true)
                if (grantResults[index] == PackageManager.PERMISSION_GRANTED) {
                    editor.putBoolean("permanent_$permission", false)
                    return@forEachIndexed
                }
                val rationaleAfter =
                    ActivityCompat.shouldShowRequestPermissionRationale(activity, permission)
                val permanent = when {
                    rationaleAfter -> false
                    // Refused a second time, or "Don't ask again".
                    rationaleBefore[permission] == true -> true
                    // Android answered without a dialog: already blocked.
                    instant -> true
                    // Dialog dismissed (Android 11+): it can be shown again.
                    else -> false
                }
                editor.putBoolean("permanent_$permission", permanent)
            }
            editor.apply()
        }
        request.callback(status(request.permissions))
        pump()
        return true
    }
}
