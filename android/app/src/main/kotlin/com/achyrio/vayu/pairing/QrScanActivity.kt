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
import android.os.Handler
import android.os.Looper
import android.util.Size
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.Button
import android.widget.ImageButton
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.CameraState
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
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
 * by QrScannerHandler immediately before this Activity is launched.
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
    private lateinit var retry: Button
    private lateinit var torch: ImageButton
    private val main = Handler(Looper.getMainLooper())
    private var camera: Camera? = null
    private var torchOn = false
    private var initAttempts = 0
    private var binding = false

    // Set while the camera is blocked or failed; cleared once it opens.
    private var cameraFailed = false
    private val reader = MultiFormatReader().apply {
        setHints(
            mapOf(
                DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
                DecodeHintType.TRY_HARDER to true,
            ),
        )
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
            text = defaultHint()
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
        retry = Button(this).apply {
            text = "Try again"
            visibility = View.GONE
            setOnClickListener { bindCamera() }
        }
        root.addView(
            retry,
            FrameLayout.LayoutParams(WRAP, WRAP, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply {
                bottomMargin = dp(24)
            },
        )
        torch = ImageButton(this).apply {
            setImageResource(android.R.drawable.ic_menu_view)
            setBackgroundColor(Color.TRANSPARENT)
            contentDescription = "Turn on the light"
            visibility = View.GONE
            setOnClickListener { toggleTorch() }
        }
        root.addView(
            torch,
            FrameLayout.LayoutParams(dp(56), dp(56), Gravity.TOP or Gravity.END).apply {
                topMargin = dp(24)
                rightMargin = dp(8)
            },
        )
        setContentView(root)
        previewView = preview

        if (hasCameraPermission()) bindCamera() else finishWithError("permission")
    }

    override fun onResume() {
        super.onResume()
        // Back from a system camera prompt (privacy switch, an OEM camera
        // prompt) or from Settings: the camera may be free now. The scanner
        // used to stay black here until the app was restarted.
        if (hasCameraPermission() && !binding && (camera == null || cameraFailed)) bindCamera()
    }

    private fun hasCameraPermission() =
        ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    private lateinit var previewView: PreviewView

    private fun bindCamera() {
        if (binding) return
        binding = true
        retry.visibility = View.GONE
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            binding = false
            try {
                val provider = future.get()
                val preview = Preview.Builder().build().also {
                    it.surfaceProvider = previewView.surfaceProvider
                }
                // Receive codes are dense (about 70 modules a side); the
                // default 640x480 frames left too few pixels per module.
                val analysis = ImageAnalysis.Builder()
                    .setResolutionSelector(
                        ResolutionSelector.Builder()
                            .setResolutionStrategy(
                                ResolutionStrategy(
                                    Size(1280, 720),
                                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                                ),
                            )
                            .build(),
                    )
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                analysis.setAnalyzer(analysisExecutor) { image -> analyze(image) }
                provider.unbindAll()
                val bound = provider.bindToLifecycle(
                    this,
                    CameraSelector.DEFAULT_BACK_CAMERA,
                    preview,
                    analysis,
                )
                camera = bound
                cameraFailed = false
                initAttempts = 0
                hint.text = defaultHint()
                torch.visibility = if (bound.cameraInfo.hasFlashUnit()) View.VISIBLE else View.GONE
                bound.cameraInfo.cameraState.removeObservers(this)
                bound.cameraInfo.cameraState.observe(this) { state -> onCameraState(state) }
            } catch (e: Exception) {
                // Right after the permission is granted some phones report no
                // camera for a moment; try a few times before giving up.
                if (++initAttempts < 3) {
                    main.postDelayed({ bindCamera() }, 700L * initAttempts)
                } else {
                    showCameraProblem("The camera could not be started. Tap Try again.")
                }
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun onCameraState(state: CameraState) {
        val error = state.error
        if (error == null) {
            if (state.type == CameraState.Type.OPEN && cameraFailed) {
                cameraFailed = false
                retry.visibility = View.GONE
                hint.text = defaultHint()
            }
            return
        }
        showCameraProblem(
            when (error.code) {
                CameraState.ERROR_CAMERA_DISABLED ->
                    "Camera access is turned off. Allow it, then tap Try again."
                CameraState.ERROR_CAMERA_IN_USE, CameraState.ERROR_MAX_CAMERAS_IN_USE ->
                    "Another app is using the camera. Close it, then tap Try again."
                CameraState.ERROR_DO_NOT_DISTURB_MODE_ENABLED ->
                    "Do Not Disturb is blocking the camera. Turn it off, then tap Try again."
                else -> "The camera stopped. Tap Try again."
            },
        )
    }

    private fun showCameraProblem(message: String) {
        cameraFailed = true
        hint.text = message
        retry.visibility = View.VISIBLE
    }

    private fun toggleTorch() {
        val cam = camera ?: return
        torchOn = !torchOn
        cam.cameraControl.enableTorch(torchOn)
        torch.contentDescription = if (torchOn) "Turn off the light" else "Turn on the light"
    }

    private fun defaultHint() =
        if (acceptCards) "Point at the card on the other phone" else "Point at the Vayu code on the other phone"

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
        main.removeCallbacksAndMessages(null)
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
