package com.achyrio.vayu.pairing

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.NotFoundException
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Full-screen camera that reads a Vayu pairing QR code and returns its text.
 *
 * CameraX delivers frames; ZXing decodes the luminance plane on a background
 * executor. Only `vayu://` (or legacy `silosend://`) codes are accepted, so a
 * random QR code can never start a connection; with [EXTRA_ACCEPT_CARDS] a
 * contact card (vCard, as shown on another phone's My card) is accepted too. The camera permission is asked
 * here, at the moment the user chose to scan.
 */
class QrScanActivity : ComponentActivity() {
    companion object {
        const val EXTRA_TEXT = "text"
        const val EXTRA_ERROR = "error"
        const val EXTRA_ACCEPT_CARDS = "accept_cards"
    }

    private val acceptCards by lazy { intent.getBooleanExtra(EXTRA_ACCEPT_CARDS, false) }

    private lateinit var analysisExecutor: ExecutorService
    private val delivered = AtomicBoolean(false)
    private lateinit var hint: TextView
    private val reader = MultiFormatReader().apply {
        setHints(
            mapOf(
                DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
                DecodeHintType.TRY_HARDER to true,
            ),
        )
    }

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) startCamera() else finishWithError("permission")
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        analysisExecutor = Executors.newSingleThreadExecutor()

        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        val preview = PreviewView(this).apply {
            id = View.generateViewId()
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
        root.addView(preview, FrameLayout.LayoutParams(MATCH, MATCH))
        root.addView(ViewfinderOverlay(this), FrameLayout.LayoutParams(MATCH, MATCH))

        hint = TextView(this).apply {
            text = if (acceptCards) {
                "Point at the card on the other phone"
            } else {
                "Point at the Vayu code on the other phone"
            }
            setTextColor(Color.parseColor("#F4F1EA"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            gravity = Gravity.CENTER
            setPadding(dp(24), 0, dp(24), dp(72))
        }
        root.addView(hint, FrameLayout.LayoutParams(MATCH, WRAP, Gravity.BOTTOM))

        val close = ImageButton(this).apply {
            setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
            setBackgroundColor(Color.TRANSPARENT)
            contentDescription = "Close scanner"
            setOnClickListener {
                setResult(Activity.RESULT_CANCELED)
                finish()
            }
        }
        root.addView(
            close,
            FrameLayout.LayoutParams(dp(56), dp(56), Gravity.TOP or Gravity.START).apply {
                topMargin = dp(24)
                leftMargin = dp(8)
            },
        )
        setContentView(root)
        previewView = preview

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            startCamera()
        } else {
            permissionLauncher.launch(Manifest.permission.CAMERA)
        }
    }

    private lateinit var previewView: PreviewView

    private fun startCamera() {
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            try {
                val provider = future.get()
                val preview = Preview.Builder().build().also {
                    it.surfaceProvider = previewView.surfaceProvider
                }
                val analysis = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                analysis.setAnalyzer(analysisExecutor) { image -> analyze(image) }
                provider.unbindAll()
                provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
            } catch (e: Exception) {
                finishWithError("camera")
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun analyze(image: ImageProxy) {
        try {
            if (delivered.get()) return
            val plane = image.planes[0]
            val buffer = plane.buffer
            val bytes = ByteArray(buffer.remaining()).also { buffer.get(it) }
            val source = PlanarYUVLuminanceSource(
                bytes,
                plane.rowStride,
                image.height,
                0,
                0,
                image.width,
                image.height,
                false,
            )
            val text = try {
                reader.decodeWithState(BinaryBitmap(HybridBinarizer(source))).text
            } catch (_: NotFoundException) {
                null
            } finally {
                reader.reset()
            }
            if (text != null) {
                val isVayuCode = text.startsWith("vayu://") || text.startsWith("silosend://")
                val isCard = acceptCards && text.trimStart().startsWith("BEGIN:VCARD", ignoreCase = true)
                if (isVayuCode || isCard) {
                    if (delivered.compareAndSet(false, true)) {
                        runOnUiThread {
                            setResult(Activity.RESULT_OK, Intent().putExtra(EXTRA_TEXT, text))
                            finish()
                        }
                    }
                } else {
                    runOnUiThread {
                        hint.text = if (acceptCards) "That is not a contact card" else "That is not a Vayu code"
                    }
                }
            }
        } catch (_: Exception) {
            // A bad frame is skipped; the next one is analyzed.
        } finally {
            image.close()
        }
    }

    private fun finishWithError(code: String) {
        setResult(Activity.RESULT_CANCELED, Intent().putExtra(EXTRA_ERROR, code))
        finish()
    }

    override fun onDestroy() {
        analysisExecutor.shutdown()
        super.onDestroy()
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    /** Dims everything except a rounded square window with soft corner marks. */
    private class ViewfinderOverlay(context: Context) : View(context) {
        private val scrim = Paint().apply { color = Color.parseColor("#99000000") }
        private val corner = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.parseColor("#8DBDAB")
            style = Paint.Style.STROKE
            strokeWidth = 4f * resources.displayMetrics.density
            strokeCap = Paint.Cap.ROUND
        }

        // Shapes are built once per size, not on every draw.
        private val window = RectF()
        private val path = Path().apply { fillType = Path.FillType.EVEN_ODD }
        private val radius = 28f * resources.displayMetrics.density

        override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
            val size = minOf(w, h) * 0.68f
            val left = (w - size) / 2f
            val top = (h - size) / 2.4f
            window.set(left, top, left + size, top + size)
            path.reset()
            path.addRect(0f, 0f, w.toFloat(), h.toFloat(), Path.Direction.CW)
            path.addRoundRect(window, radius, radius, Path.Direction.CW)
        }

        override fun onDraw(canvas: Canvas) {
            canvas.drawPath(path, scrim)
            canvas.drawRoundRect(window, radius, radius, corner)
        }
    }
}

private const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
private const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT
