package com.achyrio.vayu.contacts

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.ContactsContract
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Contact sharing (Phase 10) over channel `com.achyrio.vayu/contacts`.
 *
 * `pick` opens the system contact picker, which grants access to just the one
 * contact chosen, and returns that contact as a vCard. If a device's contacts
 * provider refuses the vCard read without READ_CONTACTS, the permission is
 * requested at that moment and the read retried once; Vayu never reads
 * contacts the user did not pick. `privateDirectory` is where received cards
 * are kept (app-private), and import goes through the contacts app via
 * PlatformHandler.openFile so the user confirms every save.
 */
class ContactsHandler(private val activity: Activity) : MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL = "com.achyrio.vayu/contacts"
        private const val REQUEST_PICK = 4106
        private const val REQUEST_PERMISSION = 4107
        private const val MAX_VCARD_BYTES = 1024 * 1024
    }

    private var channel: MethodChannel? = null
    private var pending: MethodChannel.Result? = null
    private var pickedUri: Uri? = null

    fun register(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    fun unregister() {
        channel?.setMethodCallHandler(null)
        channel = null
        pending?.success(null)
        pending = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pick" -> {
                if (pending != null) {
                    result.error("BUSY", "A contact pick is already open", null)
                    return
                }
                pending = result
                try {
                    activity.startActivityForResult(
                        Intent(Intent.ACTION_PICK, ContactsContract.Contacts.CONTENT_URI),
                        REQUEST_PICK,
                    )
                } catch (e: Exception) {
                    pending = null
                    result.error("NO_PICKER", "No contacts app available", null)
                }
            }
            "privateDirectory" -> {
                val dir = File(activity.filesDir, "contacts").apply { mkdirs() }
                result.success(dir.absolutePath)
            }
            else -> result.notImplemented()
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK) return false
        val result = pending ?: return true
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending = null
            result.success(null)
            return true
        }
        pickedUri = uri
        readPicked(allowPermissionRequest = true)
        return true
    }

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_PERMISSION) return false
        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            readPicked(allowPermissionRequest = false)
        } else {
            pending?.error("PERMISSION", "Contacts access denied", null)
            pending = null
        }
        return true
    }

    private fun readPicked(allowPermissionRequest: Boolean) {
        val result = pending ?: return
        val uri = pickedUri ?: return
        try {
            var name: String? = null
            var lookupKey: String? = null
            activity.contentResolver.query(
                uri,
                arrayOf(ContactsContract.Contacts.DISPLAY_NAME, ContactsContract.Contacts.LOOKUP_KEY),
                null,
                null,
                null,
            )?.use { c ->
                if (c.moveToFirst()) {
                    name = c.getString(0)
                    lookupKey = c.getString(1)
                }
            }
            val key = lookupKey ?: throw IllegalStateException("Contact has no lookup key")
            val vcardUri = Uri.withAppendedPath(ContactsContract.Contacts.CONTENT_VCARD_URI, key)
            val bytes = activity.contentResolver.openInputStream(vcardUri)?.use { input ->
                val out = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(16 * 1024)
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    out.write(buffer, 0, n)
                    if (out.size() > MAX_VCARD_BYTES) throw IllegalStateException("Contact card too large")
                }
                out.toByteArray()
            } ?: throw IllegalStateException("Contact card unavailable")
            pending = null
            pickedUri = null
            result.success(mapOf("name" to (name ?: "Contact"), "vcard" to bytes))
        } catch (e: SecurityException) {
            val granted = ContextCompat.checkSelfPermission(activity, Manifest.permission.READ_CONTACTS) ==
                PackageManager.PERMISSION_GRANTED
            if (allowPermissionRequest && !granted) {
                ActivityCompat.requestPermissions(
                    activity,
                    arrayOf(Manifest.permission.READ_CONTACTS),
                    REQUEST_PERMISSION,
                )
            } else {
                pending = null
                result.error("PERMISSION", "Contacts access denied", null)
            }
        } catch (e: Exception) {
            pending = null
            result.error("READ_FAILED", e.message, null)
        }
    }
}
