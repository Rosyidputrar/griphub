package id.griphub.agent

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs

/**
 * The one Flutter engine of the app, shared by the main window and the floating panel (Fitur 4): the panel is the
 * same app with the same chat, not a second copy. Made on first use, it outlives both windows.
 */
object EngineHolder {
    const val ID = "griphub-main"

    fun ensure(context: Context): String {
        val cache = FlutterEngineCache.getInstance()
        if (!cache.contains(ID)) {
            val engine = FlutterEngine(context.applicationContext)
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(context.applicationContext)
            loader.ensureInitializationComplete(context.applicationContext, null)
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            cache.put(ID, engine)
        }
        return ID
    }
}

/**
 * The floating panel's ways in and out: the permission to show above other apps (asked for only when the user first
 * uses something that needs it, from the app's own explanation screen), opening the panel, and the bubble.
 */
object Overlay {
    fun allowed(context: Context): Boolean = Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(context)

    /** The system screen where the user allows it; the app checks again when the user comes back. */
    fun openSettings(activity: Activity) {
        activity.startActivity(
            Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${activity.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }

    /**
     * Opens the panel over whatever is on screen, with [extras] (a share or a selection) when given. False without the
     * permission: the caller opens the app instead.
     */
    fun openPanel(context: Context, extras: Intent?): Boolean {
        if (!allowed(context)) return false
        // Its own task (taskAffinity), one panel at a time there.
        val intent = Intent(context, PanelActivity::class.java)
            .setAction(PanelActivity.ACTION_SHOW)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (extras != null) {
            intent.action = extras.action ?: PanelActivity.ACTION_SHOW
            extras.type?.let { intent.type = it }
            extras.extras?.let { intent.putExtras(it) }
            extras.clipData?.let { intent.clipData = it }
            intent.addFlags(extras.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(intent)
        return true
    }
}

/**
 * The floating panel: a half-screen sheet over the app the user is in, showing the shared engine in its panel look
 * (Dart: PanelScope). Its window is only as tall as the sheet and does not take touches outside it
 * (FLAG_NOT_TOUCH_MODAL), so the app behind goes on working. "Ask GripHub" (text selection) and single shares come
 * here; the reply can go back as the selection's replacement when the other app allows it.
 */
class PanelActivity : BridgeActivity() {
    companion object {
        const val ACTION_SHOW = "id.griphub.agent.PANEL"
        /** The panel, listening right away (the widget's microphone). */
        const val ACTION_VOICE = "id.griphub.agent.PANEL_VOICE"
        /** The sheet's share of the screen height. */
        private const val HEIGHT = 0.6f
    }

    override val surface = "panel"

    /** The selection this panel was opened with, and whether its app takes a replacement back. */
    private var selection: String? = null
    private var writable = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val metrics = resources.displayMetrics
        window.setLayout(WindowManager.LayoutParams.MATCH_PARENT, (metrics.heightPixels * HEIGHT).toInt())
        window.setGravity(Gravity.BOTTOM)
        // Touches outside the sheet go to the app behind it.
        window.addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL)
        window.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        // The bubble is the panel folded away: no need for both on screen.
        BubbleService.hide(this)
    }

    override fun surfaceInfo(): Map<String, Any?> = mapOf(
        "selection" to selection,
        "writable" to writable,
    )

    override fun handleIntent(intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_PROCESS_TEXT -> {
                selection = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
                writable = !intent.getBooleanExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, true) && callingActivity != null
                launch(mapOf("action" to "panel_selection", "text" to selection, "writable" to writable))
            }
            // A single share routed here by ShareActivity: the same shape the app reads (text, files).
            Intent.ACTION_SEND -> super.handleIntent(intent)
            ACTION_VOICE -> {
                selection = null
                writable = false
                launch(mapOf("action" to "panel_voice"))
            }
            else -> {
                selection = null
                writable = false
                launch(mapOf("action" to "panel"))
            }
        }
    }

    override fun handlePanelCall(method: String, arguments: Any?, result: MethodChannel.Result): Boolean {
        when (method) {
            // Folded into the bubble at the screen's edge.
            "panelMinimize" -> {
                BubbleService.show(this)
                finish()
                result.success(null)
            }
            "panelClose" -> {
                BubbleService.stop(this)
                finish()
                result.success(null)
            }
            // The same chat, in the whole app.
            "panelOpenFull" -> {
                startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP))
                finish()
                result.success(null)
            }
            // The answer goes back into the other app in place of the selection, when it allows that.
            "panelReplaceText" -> {
                if (!writable) {
                    result.error("read_only", "This app does not take the text back", null)
                } else {
                    setResult(RESULT_OK, Intent().putExtra(Intent.EXTRA_PROCESS_TEXT, arguments as? String ?: ""))
                    finish()
                    result.success(true)
                }
            }
            else -> return false
        }
        return true
    }
}

/**
 * "Tanya GripHub" in another app's text selection menu. No window of its own: the panel when it may show (in the
 * calling app's task, with the result forwarded, so a replacement can go back into the selection), else the app with
 * the selection in a new chat. The engine is not touched here.
 */
class ProcessTextActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val source = intent
        if (Overlay.allowed(this)) {
            startActivity(
                Intent(source).setClass(this, PanelActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_FORWARD_RESULT),
            )
        } else {
            startActivity(
                Intent(source).setClass(this, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            )
        }
        finish()
    }
}

/**
 * Where a single share lands: the panel when it may show over other apps, else the app as before. Several files still
 * go to the app (MainActivity's own filter). No window of its own.
 */
class ShareActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val source = intent
        // Text, a link or one picture opens the panel (Fitur 4 butir A2); other files go to the app as they always did.
        val type = source.type ?: ""
        val forPanel = type.startsWith("text/") || type.startsWith("image/")
        if (!forPanel || !Overlay.openPanel(this, source)) {
            startActivity(
                Intent(source).setClass(this, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            )
        }
        finish()
    }
}

/**
 * The bubble: the panel folded to a small handle at the screen's edge, over other apps. It can be dragged along the
 * edge, tapped to open the panel, or dragged to the bottom to put it away. A foreground service with its own
 * notification, so the panel's presence is never hidden; it runs only while the bubble is out, and polls nothing.
 */
class BubbleService : Service() {
    companion object {
        private const val CHANNEL = "panel"
        private const val NOTIFICATION = 31
        private const val ACTION_STOP = "id.griphub.agent.BUBBLE_STOP"

        fun show(context: Context) {
            if (!Overlay.allowed(context)) return
            val intent = Intent(context, BubbleService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
        }

        /** The panel is open: the bubble steps aside (the service stays only while the bubble shows). */
        fun hide(context: Context) = stop(context)

        fun stop(context: Context) {
            context.stopService(Intent(context, BubbleService::class.java))
        }
    }

    private var view: View? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        startForegroundCompat()
        if (view == null && Overlay.allowed(this)) addBubble()
        if (view == null) stopSelf()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        view?.let { (getSystemService(WINDOW_SERVICE) as WindowManager).removeView(it) }
        view = null
        super.onDestroy()
    }

    private fun startForegroundCompat() {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, Notifications.t(this, "Floating panel", "Panel mengambang"), NotificationManager.IMPORTANCE_MIN),
            )
        }
        val open = PendingIntent.getActivity(
            this, 40,
            Intent(this, PanelActivity::class.java).setAction(PanelActivity.ACTION_SHOW).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(this, 41, Intent(this, BubbleService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
        val n = builder
            .setSmallIcon(R.drawable.ic_stat_agent)
            .setContentTitle(Notifications.t(this, "GripHub panel is on screen", "Panel GripHub ada di layar"))
            .setContentText(Notifications.t(this, "Tap to open it", "Ketuk untuk membukanya"))
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, Notifications.t(this, "Close", "Tutup"), stop).build())
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION, n)
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun addBubble() {
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        val density = resources.displayMetrics.density
        val size = (52 * density).toInt()
        val bubble = FrameLayout(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(0xFF1C1B22.toInt())
                setStroke((1.5f * density).toInt(), 0x33FFFFFF)
            }
            elevation = 6 * density
            contentDescription = Notifications.t(this@BubbleService, "Open the GripHub panel", "Buka panel GripHub")
            addView(
                ImageView(this@BubbleService).apply {
                    setImageResource(R.mipmap.ic_launcher)
                    val pad = (8 * density).toInt()
                    setPadding(pad, pad, pad, pad)
                },
                FrameLayout.LayoutParams(size, size),
            )
        }
        val type = if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
        val metrics = resources.displayMetrics
        // Small, at the right edge, a third of the way down: out of the middle of the screen.
        val params = WindowManager.LayoutParams(
            size, size, type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = metrics.widthPixels - size - (4 * density).toInt()
            y = metrics.heightPixels / 3
        }
        var downX = 0f
        var downY = 0f
        var startX = 0
        var startY = 0
        var moved = false
        bubble.setOnTouchListener { v, e ->
            when (e.action) {
                MotionEvent.ACTION_DOWN -> {
                    downX = e.rawX; downY = e.rawY; startX = params.x; startY = params.y; moved = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = e.rawX - downX
                    val dy = e.rawY - downY
                    if (abs(dx) > 8 * density || abs(dy) > 8 * density) moved = true
                    params.x = (startX + dx).toInt()
                    params.y = (startY + dy).toInt()
                    wm.updateViewLayout(v, params)
                    true
                }
                MotionEvent.ACTION_UP -> {
                    when {
                        // Dropped at the bottom of the screen: put away.
                        moved && e.rawY > metrics.heightPixels * 0.88f -> stopSelf()
                        moved -> {
                            // Back to the nearest edge, out of the way.
                            params.x = if (e.rawX < metrics.widthPixels / 2) (4 * density).toInt() else metrics.widthPixels - size - (4 * density).toInt()
                            wm.updateViewLayout(v, params)
                        }
                        else -> {
                            Overlay.openPanel(this, null)
                        }
                    }
                    true
                }
                else -> false
            }
        }
        wm.addView(bubble, params)
        view = bubble
    }
}
