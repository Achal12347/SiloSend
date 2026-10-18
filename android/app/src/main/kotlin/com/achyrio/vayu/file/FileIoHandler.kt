package com.achyrio.vayu.file

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Reads picked documents for outbound transfers on a background task queue.
 *
 * Chunk reads and whole-file hashing used to run on the Android main thread, which
 * competes with rendering and risks ANRs on large files. Hashing natively also replaces
 * thousands of per-chunk channel round trips with a single call.
 */
class FileIoHandler(private val context: Context) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "com.achyrio.vayu/file_io"
        private const val HASH_BUFFER = 1024 * 1024

        // Hashing runs beside the transfer (the offer no longer waits for it), so
        // it must not hold the serial channel queue that chunk reads go through.
        // One pool per process: handlers are recreated with the activity.
        private val hashers: ExecutorService = Executors.newFixedThreadPool(2)
    }

    private class OpenFile(val descriptor: ParcelFileDescriptor) {
        val stream = FileInputStream(descriptor.fileDescriptor)
        val channel: FileChannel = stream.channel

        fun close() {
            try {
                stream.close()
            } catch (_: Exception) {}
            try {
                descriptor.close()
            } catch (_: Exception) {}
        }
    }

    private var channel: MethodChannel? = null
    private val openFiles = ConcurrentHashMap<String, OpenFile>()

    private val main = Handler(Looper.getMainLooper())

    fun register(messenger: BinaryMessenger) {
        val queue = messenger.makeBackgroundTaskQueue()
        channel = MethodChannel(messenger, CHANNEL, StandardMethodCodec.INSTANCE, queue).also {
            it.setMethodCallHandler(this)
        }
    }

    fun unregister() {
        channel?.setMethodCallHandler(null)
        channel = null
        openFiles.values.forEach { it.close() }
        openFiles.clear()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val uriString = call.argument<String>("uri")
        if (uriString == null) {
            result.error("INVALID_ARGS", "Missing URI parameter", null)
            return
        }
        when (call.method) {
            "readChunk" -> readChunk(uriString, call, result)
            "sha256" -> hashers.execute { sha256(uriString, result) }
            "closeFile" -> {
                openFiles.remove(uriString)?.close()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun open(uriString: String): OpenFile =
        openFiles.computeIfAbsent(uriString) {
            val pfd = context.contentResolver.openFileDescriptor(Uri.parse(uriString), "r")
                ?: throw IllegalArgumentException("Cannot open descriptor")
            OpenFile(pfd)
        }

    private fun readChunk(uriString: String, call: MethodCall, result: MethodChannel.Result) {
        val offset = (call.argument<Number>("offset") ?: 0L).toLong()
        val length = (call.argument<Number>("length") ?: 0).toInt()
        try {
            val file = open(uriString)
            val buffer = ByteBuffer.allocate(length)
            var position = offset
            // Positional reads loop because one read may return fewer bytes than asked.
            while (buffer.hasRemaining()) {
                val read = file.channel.read(buffer, position)
                if (read <= 0) break
                position += read
            }
            val filled = buffer.position()
            result.success(if (filled == length) buffer.array() else buffer.array().copyOf(filled))
        } catch (e: Exception) {
            result.error("READ_FAILED", "Failed to read chunk at offset $offset: ${e.message}", null)
        }
    }

    private fun sha256(uriString: String, result: MethodChannel.Result) {
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            var total = 0L
            // Separate descriptor so hashing never disturbs an in-progress chunk reader.
            context.contentResolver.openInputStream(Uri.parse(uriString)).use { input ->
                if (input == null) throw IllegalArgumentException("Cannot open stream")
                val buffer = ByteArray(HASH_BUFFER)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    digest.update(buffer, 0, read)
                    total += read
                }
            }
            val hex = digest.digest().joinToString("") { "%02x".format(it) }
            main.post { result.success(mapOf("sha256" to hex, "size" to total)) }
        } catch (e: Exception) {
            main.post { result.error("HASH_FAILED", "Failed to hash document: ${e.message}", null) }
        }
    }
}
