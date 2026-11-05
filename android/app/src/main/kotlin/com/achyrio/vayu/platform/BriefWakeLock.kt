package com.achyrio.vayu.platform

import android.content.Context
import android.os.PowerManager

/**
 * Keeps the CPU awake for a moment after something arrives with the screen
 * off, long enough to connect, decrypt, save and notify. Timed, so nothing can
 * keep the phone awake if a release is missed.
 */
object BriefWakeLock {
    private const val HOLD_MS = 15_000L
    private var lock: PowerManager.WakeLock? = null

    @Synchronized
    fun hold(context: Context) {
        val current = lock ?: (context.applicationContext
            .getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Vayu:incoming")
            .apply { setReferenceCounted(false) }
            .also { lock = it }
        current.acquire(HOLD_MS)
    }
}
