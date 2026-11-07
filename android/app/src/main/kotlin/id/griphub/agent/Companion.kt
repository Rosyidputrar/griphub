package id.griphub.agent

import android.accessibilityservice.AccessibilityService
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.RectF
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.provider.Settings
import android.util.Base64
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.sqrt

/**
 * Screen companion (Fitur 5): the agent sees the user's screen, one frame when a step needs it, and points at things;
 * the user's finger does everything. Nothing in this file taps, swipes or types into another app.
 *
 * - The user starts it, every time: Android's own consent dialog (MediaProjection) for each session, then a foreground
 *   service of type mediaProjection with a Stop button; Android shows its own capture indicator meanwhile.
 * - A frame is taken only when asked for: the virtual display (one per consent, as Android 14 requires) renders into
 *   nothing between requests (its surface is detached), so there is no stream. The frame goes to Flutter, then to the
 *   router for one request; it is never written to a file here.
 * - A secure screen (FLAG_SECURE: banking, password fields) comes out black; the frame's brightness statistics go
 *   with it so the app can tell and say so. Nothing tries to get around it.
 */
object ScreenCompanion {
    private const val CHANNEL = "companion"
    const val NOTIFICATION = 32

    @Volatile private var projection: MediaProjection? = null
    @Volatile private var display: VirtualDisplay? = null
    @Volatile private var reader: ImageReader? = null
    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var width = 0
    private var height = 0
    private var density = 0

    val active: Boolean get() = projection != null

    /** The system consent screen; the activity starts the service with its answer. */
    fun consentIntent(context: Context): Intent =
        (context.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager).createScreenCaptureIntent()

    /** Called by CompanionService once it is in the foreground (Android requires that order). */
    fun begin(context: Context, resultCode: Int, data: Intent) {
        val manager = context.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val p = manager.getMediaProjection(resultCode, data) ?: throw IllegalStateException("No consent")
        val metrics = context.resources.displayMetrics
        // Half the screen's size: enough to read and point, a quarter of the pixels to send.
        width = metrics.widthPixels / 2
        height = metrics.heightPixels / 2
        density = metrics.densityDpi
        thread = HandlerThread("companion").also { it.start() }
        handler = Handler(thread!!.looper)
        p.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                end(context)
            }
        }, handler)
        val r = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
        // Created once (Android 14: one virtual display per consent), rendering into nothing until a frame is asked for.
        display = p.createVirtualDisplay("griphub-companion", width, height, density, DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, null, null, handler)
        reader = r
        projection = p
    }

    /**
     * One frame now: JPEG as base64, its size, the screen's size, and brightness statistics (mean, deviation) the app
     * reads to tell a secure (black) screen. Null when the companion is not on or no frame came.
     */
    fun capture(context: Context): Map<String, Any?>? {
        val d = display ?: return null
        val r = reader ?: return null
        val latch = CountDownLatch(1)
        var bitmap: Bitmap? = null
        r.setOnImageAvailableListener({ ir ->
            val image = try { ir.acquireLatestImage() } catch (e: Exception) { null } ?: return@setOnImageAvailableListener
            try {
                val plane = image.planes[0]
                val rowPadding = plane.rowStride - plane.pixelStride * width
                val full = Bitmap.createBitmap(width + rowPadding / plane.pixelStride, height, Bitmap.Config.ARGB_8888)
                full.copyPixelsFromBuffer(plane.buffer)
                bitmap = Bitmap.createBitmap(full, 0, 0, width, height)
                if (full !== bitmap) full.recycle()
            } finally {
                image.close()
            }
            // Back to rendering into nothing: no frames between requests.
            d.surface = null
            latch.countDown()
        }, handler)
        d.surface = r.surface
        latch.await(3, TimeUnit.SECONDS)
        r.setOnImageAvailableListener(null, null)
        d.surface = null
        val b = bitmap ?: return null
        val (mean, deviation) = brightness(b)
        val out = ByteArrayOutputStream()
        b.compress(Bitmap.CompressFormat.JPEG, 70, out)
        b.recycle()
        val metrics = context.resources.displayMetrics
        return mapOf(
            "data" to Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP),
            "mimeType" to "image/jpeg",
            "width" to width,
            "height" to height,
            "screenWidth" to metrics.widthPixels,
            "screenHeight" to metrics.heightPixels,
            "mean" to mean,
            "deviation" to deviation,
        )
    }

    /** Mean and standard deviation of the brightness of a sample of pixels (0..255). */
    private fun brightness(b: Bitmap): Pair<Double, Double> {
        var n = 0
        var sum = 0.0
        var sq = 0.0
        val step = maxOf(4, minOf(b.width, b.height) / 48)
        var y = 0
        while (y < b.height) {
            var x = 0
            while (x < b.width) {
                val c = b.getPixel(x, y)
                val l = 0.299 * Color.red(c) + 0.587 * Color.green(c) + 0.114 * Color.blue(c)
                sum += l
                sq += l * l
                n++
                x += step
            }
            y += step
        }
        if (n == 0) return 0.0 to 0.0
        val mean = sum / n
        return mean to sqrt(maxOf(0.0, sq / n - mean * mean))
    }

    /** Stops capture at once: projection, display and service go together. */
    fun end(context: Context) {
        try { display?.release() } catch (e: Exception) {}
        try { reader?.close() } catch (e: Exception) {}
        try { projection?.stop() } catch (e: Exception) {}
        display = null
        reader = null
        projection = null
        thread?.quitSafely()
        thread = null
        handler = null
        Highlight.clear(context)
        context.stopService(Intent(context, CompanionService::class.java))
        BridgeActivity.emit(mapOf("kind" to "companion", "active" to false))
    }

    fun notification(context: Context): Notification {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, Notifications.t(context, "Screen companion", "Pendamping layar"), NotificationManager.IMPORTANCE_LOW),
            )
        }
        val stop = PendingIntent.getService(
            context, 42, Intent(context, CompanionService::class.java).setAction(CompanionService.ACTION_STOP), PendingIntent.FLAG_IMMUTABLE,
        )
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL) else Notification.Builder(context)
        return builder
            .setSmallIcon(R.drawable.ic_stat_agent)
            .setContentTitle(Notifications.t(context, "GripHub can see your screen", "GripHub bisa melihat layarmu"))
            .setContentText(Notifications.t(context, "Only when a step needs it. Tap Stop to end now.", "Hanya saat sebuah langkah membutuhkannya. Ketuk Berhenti untuk mengakhiri sekarang."))
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, Notifications.t(context, "Stop", "Berhenti"), stop).build())
            .build()
    }
}

/** The companion's foreground service (type mediaProjection), alive exactly while capture is allowed. */
class CompanionService : Service() {
    companion object {
        const val ACTION_STOP = "id.griphub.agent.COMPANION_STOP"
        const val EXTRA_CODE = "code"
        const val EXTRA_DATA = "data"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            ScreenCompanion.end(this)
            stopSelf()
            return START_NOT_STICKY
        }
        val n = ScreenCompanion.notification(this)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(ScreenCompanion.NOTIFICATION, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(ScreenCompanion.NOTIFICATION, n)
        }
        @Suppress("DEPRECATION")
        val data = intent?.getParcelableExtra<Intent>(EXTRA_DATA)
        val code = intent?.getIntExtra(EXTRA_CODE, 0) ?: 0
        try {
            if (data == null) throw IllegalStateException("No consent")
            ScreenCompanion.begin(this, code, data)
            BridgeActivity.emit(mapOf("kind" to "companion", "active" to true))
        } catch (e: Exception) {
            ScreenCompanion.end(this)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (ScreenCompanion.active) ScreenCompanion.end(this)
        super.onDestroy()
    }
}

/**
 * The highlight over other apps: a frame around the element of the step, drawn above everything and touching nothing
 * (FLAG_NOT_TOUCHABLE: every touch goes to the app below). Uses the floating panel's permission (Fitur 4).
 */
object Highlight {
    private var view: View? = null

    fun show(context: Context, rect: Rect) {
        if (!Overlay.allowed(context)) return
        clear(context)
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val density = context.resources.displayMetrics.density
        val v = object : View(context) {
            private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = 3 * density
                color = 0xFF8B5CF6.toInt()
            }
            private val glow = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.FILL
                color = 0x228B5CF6
            }

            override fun onDraw(canvas: Canvas) {
                val pad = 6 * density
                val r = RectF(rect.left - pad, rect.top - pad, rect.right + pad, rect.bottom + pad)
                canvas.drawRoundRect(r, 12 * density, 12 * density, glow)
                canvas.drawRoundRect(r, 12 * density, 12 * density, paint)
            }
        }
        val type = if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT, type,
            WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        )
        wm.addView(v, params)
        view = v
    }

    fun clear(context: Context) {
        val v = view ?: return
        try {
            (context.getSystemService(Context.WINDOW_SERVICE) as WindowManager).removeView(v)
        } catch (e: Exception) {
        }
        view = null
    }
}

/**
 * The screen's elements, for pointing precisely (optional; the user turns it on in Android's accessibility settings,
 * after the app's explanation). It only reads: no gestures (canPerformGestures="false"), no actions, and text of
 * password fields is never read. It reads only when the companion asks, and keeps nothing.
 */
class CompanionAccessibilityService : AccessibilityService() {
    companion object {
        @Volatile
        var instance: CompanionAccessibilityService? = null

        fun enabled(context: Context): Boolean {
            val list = Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
            return list.split(':').any { it.endsWith("/.CompanionAccessibilityService") || it.endsWith("CompanionAccessibilityService") }
        }
    }

    override fun onServiceConnected() {
        instance = this
    }

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Nothing: it reads the screen only when the companion asks (tree()).
    }

    override fun onInterrupt() {}

    /** The visible elements with text, and their boxes in screen pixels; password fields carry no text. */
    fun tree(): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        val root = rootInActiveWindow ?: return out
        var next = 0
        fun walk(n: AccessibilityNodeInfo?, depth: Int) {
            if (n == null || depth > 40 || out.size >= 150) return
            if (n.isVisibleToUser) {
                val text = if (n.isPassword) null else n.text?.toString()?.trim()?.takeIf { it.isNotEmpty() }
                val desc = n.contentDescription?.toString()?.trim()?.takeIf { it.isNotEmpty() }
                if (text != null || desc != null || n.isClickable) {
                    val r = Rect()
                    n.getBoundsInScreen(r)
                    if (r.width() > 0 && r.height() > 0) {
                        out.add(mapOf("id" to "n${next++}", "text" to text, "desc" to desc, "x" to r.left, "y" to r.top, "w" to r.width(), "h" to r.height()))
                    }
                }
            }
            for (i in 0 until n.childCount) walk(n.getChild(i), depth + 1)
        }
        walk(root, 0)
        return out
    }
}
