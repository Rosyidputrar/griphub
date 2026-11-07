package id.griphub.agent

import android.Manifest
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import android.provider.Settings
import android.speech.RecognizerIntent
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * FragmentActivity (not FlutterActivity) because the biometric lock needs it. The base of both windows of the app,
 * MainActivity and the floating panel (PanelActivity): they show the same Flutter engine (EngineHolder), so the panel
 * and the app are one app with one chat, not two. Besides the agent bridge, this handles what the rest of Android
 * sends us: shares from other apps, widget/tile shortcuts, voice input results.
 *
 * What belongs to the engine rather than to one window (the event sink, a launch Flutter has not taken yet, which
 * window holds the engine) lives in the companion: a window that took the engine over registers the channels again
 * with itself, and a window whose engine was taken builds itself again when it comes back (onResume).
 */
abstract class BridgeActivity : FlutterFragmentActivity() {
    companion object {
        private const val VOICE_REQUEST = 4101
        private const val COMPANION_REQUEST = 4102

        /** How old a pasted or shared copy in the cache is before it is swept. */
        private const val OLD_COPY_MS = 24L * 60 * 60 * 1000

        /** The Dart side's event stream (one per engine; a sink made before a window change stays valid). */
        @Volatile
        private var events: EventChannel.EventSink? = null

        /** A launch reason Flutter has not picked up yet: a share or a shortcut. */
        @Volatile
        private var pendingLaunch: Map<String, Any?>? = null

        /** The window ("app" or "panel") [pendingLaunch] is for: only that one takes it. */
        @Volatile
        private var pendingSurface: String? = null

        /** The window the engine is attached to now. */
        @Volatile
        private var owner: java.lang.ref.WeakReference<BridgeActivity>? = null

        /** App lock's FLAG_SECURE (setSecure), kept for the engine: every window that shows it gets it too. */
        @Volatile
        private var secure = false

        private val main by lazy { android.os.Handler(android.os.Looper.getMainLooper()) }

        /**
         * Sends an event to Flutter. Flutter takes platform messages on the main thread only (from any other it throws,
         * which ends the process): callers on other threads (the screen companion's capture thread, MediaProjection's
         * stop callback) are moved there.
         */
        fun emit(event: Map<String, Any?>) {
            if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) {
                events?.success(event)
            } else {
                main.post { events?.success(event) }
            }
        }

        /**
         * A launch for Flutter to pick up (takeLaunch), meant for the window [surface]. It is announced when that window
         * shows (onResume), after it told Flutter it is the one on screen: announced earlier, the window that was on
         * screen before would take it (a share opening the panel landed in the hidden app, and the other way round).
         */
        fun queueLaunch(map: Map<String, Any?>, surface: String) {
            pendingLaunch = map
            pendingSurface = surface
        }
    }

    /** Which window this is, for Flutter: "app" or "panel". */
    abstract val surface: String

    /** What Flutter needs to know about this window when it shows (the panel's context). */
    open fun surfaceInfo(): Map<String, Any?> = emptyMap()

    private var pendingVoice: MethodChannel.Result? = null
    private var pendingCompanion: MethodChannel.Result? = null

    /** Both windows show the one cached engine; it outlives either of them. */
    override fun getCachedEngineId(): String = EngineHolder.ensure(applicationContext)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // App lock is on for the engine, so for this window too (Flutter sent it once, to another window perhaps).
        if (secure) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        if (savedInstanceState == null) {
            sweepOldCopies()
            handleIntent(intent)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        // The other window took the engine while this one was away: Flutter detached from this one for good, so it is
        // built again around the same engine (the app's state is in the engine and stays as it was).
        if (owner?.get() !== this) {
            recreate()
            return
        }
        emit(mapOf("kind" to "surface", "surface" to surface) + surfaceInfo())
        if (pendingLaunch != null && pendingSurface == surface) emit(mapOf("kind" to "launch"))
    }

    /** A launch for this window (announced when it shows, see queueLaunch). */
    protected fun launch(map: Map<String, Any?>) = queueLaunch(map, surface)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        owner = java.lang.ref.WeakReference(this)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        EventChannel(messenger, "griphub/agent/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                events = sink
            }

            override fun onCancel(arguments: Any?) {
                events = null
            }
        })

        AgentRuntime.listener = object : AgentRuntime.Listener {
            override fun onStdout(line: String) {
                events?.success(mapOf("kind" to "stdout", "line" to line))
            }

            override fun onStderr(line: String) {
                events?.success(mapOf("kind" to "stderr", "line" to line))
            }

            override fun onExit(code: Int) {
                // Only the chat side ends here; schedules keep the service
                // alive through keepAlive until they are switched off.
                AgentService.setBusy(this@BridgeActivity, false)
                events?.success(mapOf("kind" to "exit", "code" to code))
            }
        }

        MethodChannel(messenger, "griphub/agent").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> {
                        // Extracting assets on first launch takes a moment; keep it off the UI thread.
                        Thread {
                            try {
                                @Suppress("UNCHECKED_CAST")
                                val extra = (call.arguments as? Map<String, String>) ?: emptyMap()
                                // The store key goes to the agent host only, never to shells.
                                AgentRuntime.start(applicationContext, extra + ("GRIPHUB_STORE_KEY" to SecureKey.hex(applicationContext)))
                                runOnUiThread { result.success(AgentRuntime.paths(applicationContext)) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("start_failed", e.message, null) }
                            }
                        }.start()
                    }
                    // A server agent: the app runs ssh to the server's attach program instead of its own host.
                    "startRemote" -> {
                        Thread {
                            try {
                                @Suppress("UNCHECKED_CAST")
                                val argv = (call.argument<List<String>>("argv") ?: emptyList())
                                @Suppress("UNCHECKED_CAST")
                                val env = (call.argument<Map<String, String>>("env") ?: emptyMap())
                                AgentRuntime.startRemote(applicationContext, argv, env)
                                runOnUiThread { result.success(AgentRuntime.paths(applicationContext)) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("start_failed", e.message, null) }
                            }
                        }.start()
                    }
                    "send" -> {
                        AgentRuntime.send(call.arguments as String)
                        result.success(null)
                    }
                    "stop" -> {
                        AgentRuntime.stop()
                        result.success(null)
                    }
                    "isRunning" -> result.success(AgentRuntime.isRunning)
                    // Android's own flag for phones with little memory (as ArchiveTune reads it): animations default off.
                    "isLowRamDevice" -> result.success(
                        (getSystemService(ACTIVITY_SERVICE) as? android.app.ActivityManager)?.isLowRamDevice == true
                    )
                    // The toolchain environment, for terminals the app opens.
                    // Unpacking the agent bundle after an update takes a moment: off the UI thread.
                    "environment" -> Thread {
                        try {
                            val env = AgentRuntime.prepareEnvironment(applicationContext)
                            runOnUiThread { result.success(env) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("environment_failed", e.message, null) }
                        }
                    }.start()
                    "setBusy" -> {
                        AgentService.setBusy(this, call.arguments as Boolean)
                        result.success(null)
                    }
                    // What the agent is doing, for the ongoing notification.
                    "busyText" -> {
                        AgentService.update(this, call.argument<String>("title"), call.argument<String>("text"))
                        result.success(null)
                    }
                    // Keeps the process alive for queued runs and schedules.
                    "keepAlive" -> {
                        val on = call.argument<Boolean>("on") == true
                        AgentService.setKeepAlive(
                            this, on,
                            text = call.argument<String>("text")
                                ?: Notifications.t(this, "Background tasks active", "Background task aktif"),
                        )
                        result.success(null)
                    }
                    // Shared storage: "All files access" is granted in system settings.
                    "storageAccess" -> result.success(
                        mapOf(
                            "available" to storageAccessDeclared(),
                            "granted" to (storageAccessDeclared() && hasStorageAccess()),
                            "root" to Environment.getExternalStorageDirectory().path,
                        )
                    )
                    "requestStorageAccess" -> {
                        if (Build.VERSION.SDK_INT >= 30) {
                            startActivity(
                                Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName"))
                            )
                        } else {
                            requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), 1)
                        }
                        result.success(null)
                    }
                    // Text to a chat app, an email or a note (an exported chat): plain text, as most of them take it.
                    "shareText" -> {
                        try {
                            val send = Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(Intent.EXTRA_TEXT, call.argument<String>("text") ?: "")
                                call.argument<String>("subject")?.let { putExtra(Intent.EXTRA_SUBJECT, it) }
                            }
                            startActivity(Intent.createChooser(send, call.argument<String>("subject")))
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("share_failed", e.message, null)
                        }
                    }
                    "shareFile" -> {
                        try {
                            val file = shareableFile(File(call.argument<String>("path")!!))
                            val uri = FileProvider.getUriForFile(this, "id.griphub.agent.files", file)
                            val send = Intent(Intent.ACTION_SEND).apply {
                                type = mimeOf(file.name)
                                putExtra(Intent.EXTRA_STREAM, uri)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            startActivity(Intent.createChooser(send, file.name))
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("share_failed", e.message, null)
                        }
                    }
                    // Explicit recovery after SecureKey.hex() refuses an
                    // un-unwrappable key: rotate it; saved tokens must be
                    // entered again, but nothing is lost silently.
                    "resetStoreKey" -> {
                        SecureKey.resetHex(applicationContext)
                        result.success(null)
                    }
                    // FLAG_SECURE while app lock is on: the system must not
                    // snapshot chats into Recents thumbnails or screenshots.
                    "setSecure" -> {
                        secure = call.arguments as? Boolean == true
                        if (secure) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(null)
                    }
                    "saveToDownloads" -> {
                        try {
                            result.success(saveToDownloads(File(call.argument<String>("path")!!)))
                        } catch (e: Exception) {
                            result.error("save_failed", e.message, null)
                        }
                    }
                    "openUrl" -> {
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(call.arguments as String)))
                        result.success(null)
                    }
                    // Voice input through the system recognizer (no mic permission needed here).
                    "listen" -> {
                        pendingVoice?.error("cancelled", "Another voice request started", null)
                        pendingVoice = result
                        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                            putExtra(RecognizerIntent.EXTRA_PROMPT, "Speak to pi")
                            call.argument<String>("language")?.let { putExtra(RecognizerIntent.EXTRA_LANGUAGE, it) }
                        }
                        try {
                            @Suppress("DEPRECATION")
                            startActivityForResult(intent, VOICE_REQUEST)
                        } catch (e: Exception) {
                            pendingVoice = null
                            result.error("unavailable", "No speech recognizer on this device", null)
                        }
                    }
                    // A picture on the clipboard (copied from a browser, a gallery, a screenshot tool): whether there is one,
                    // for the composer's "Paste image", and a copy of it in the cache to attach.
                    "clipboardHasImage" -> result.success(clipboardImageUri() != null)
                    "clipboardImage" -> result.success(clipboardImageUri()?.let { copyClipboardImage(it) })
                    // Only the window a launch is for takes it (an older app that names none takes any).
                    "takeLaunch" -> {
                        val wanted = call.arguments as? String
                        if (pendingLaunch != null && (wanted == null || wanted == pendingSurface)) {
                            result.success(pendingLaunch)
                            pendingLaunch = null
                            pendingSurface = null
                        } else {
                            result.success(null)
                        }
                    }
                    "notify" -> {
                        @Suppress("UNCHECKED_CAST")
                        val actions = (call.argument<List<Map<String, Any?>>>("actions") ?: emptyList()).map {
                            (it["label"] as String) to (it["launch"] as Map<String, Any?>)
                        }
                        Notifications.post(
                            this,
                            call.argument<Int>("id") ?: 100,
                            call.argument<String>("channel") ?: Notifications.CHATS,
                            call.argument<String>("title") ?: "GripHub AI Agent",
                            call.argument<String>("body") ?: "",
                            call.argument<Map<String, Any?>>("launch"),
                            actions,
                        )
                        result.success(null)
                    }
                    "cancelNotification" -> {
                        Notifications.cancel(this, call.arguments as Int)
                        result.success(null)
                    }
                    "requestNotifications" -> {
                        if (Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 2)
                        }
                        result.success(null)
                    }
                    // The floating panel (Fitur 4): whether it may show, the way to allow it, and its own controls.
                    "overlayPermission" -> result.success(Overlay.allowed(this))
                    "requestOverlayPermission" -> {
                        Overlay.openSettings(this)
                        result.success(null)
                    }
                    "panelOpen" -> {
                        result.success(Overlay.openPanel(this, null))
                    }
                    // Screen companion (Companion.kt, Fitur 5): Android's own consent every session, frames only on request,
                    // a highlight that takes no touches, and the optional read-only accessibility tree.
                    "companionStart" -> {
                        pendingCompanion?.success(false)
                        pendingCompanion = result
                        @Suppress("DEPRECATION")
                        startActivityForResult(ScreenCompanion.consentIntent(this), COMPANION_REQUEST)
                    }
                    "companionActive" -> result.success(ScreenCompanion.active)
                    // The panel steps out of the picture while the frame is taken (else the model mostly sees GripHub):
                    // fully transparent for a moment, then back.
                    "companionCapture" -> {
                        val hide = surface == "panel"
                        if (hide) window.attributes = window.attributes.apply { alpha = 0f }
                        Thread {
                            if (hide) Thread.sleep(250)
                            val frame = try { ScreenCompanion.capture(applicationContext) } catch (e: Exception) { null }
                            runOnUiThread {
                                if (hide) window.attributes = window.attributes.apply { alpha = 1f }
                                result.success(frame)
                            }
                        }.start()
                    }
                    "companionStop" -> {
                        ScreenCompanion.end(applicationContext)
                        result.success(null)
                    }
                    "companionHighlight" -> {
                        val x = call.argument<Int>("x") ?: 0
                        val y = call.argument<Int>("y") ?: 0
                        Highlight.show(applicationContext, android.graphics.Rect(x, y, x + (call.argument<Int>("w") ?: 0), y + (call.argument<Int>("h") ?: 0)))
                        result.success(null)
                    }
                    "companionClearHighlight" -> {
                        Highlight.clear(applicationContext)
                        result.success(null)
                    }
                    "a11yStatus" -> result.success(CompanionAccessibilityService.enabled(this))
                    "a11yOpenSettings" -> {
                        startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(null)
                    }
                    "a11yTree" -> result.success(CompanionAccessibilityService.instance?.tree() ?: emptyList<Map<String, Any?>>())
                    // The home-screen widgets' snapshot (Widgets.kt), pushed whenever what they show changes.
                    "widgetState" -> {
                        WidgetState.save(applicationContext, call.arguments as String)
                        result.success(null)
                    }
                    else -> if (!handlePanelCall(call.method, call.arguments, result)) result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("error", e.message, null)
            }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == COMPANION_REQUEST) {
            val waiting = pendingCompanion
            pendingCompanion = null
            if (resultCode != RESULT_OK || data == null) {
                waiting?.success(false)
                return
            }
            val service = Intent(this, CompanionService::class.java)
                .putExtra(CompanionService.EXTRA_CODE, resultCode)
                .putExtra(CompanionService.EXTRA_DATA, data)
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(service) else startService(service)
            waiting?.success(true)
            return
        }
        if (requestCode != VOICE_REQUEST) return
        val text = data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()
        pendingVoice?.success(text)
        pendingVoice = null
    }

    /** Calls only the panel window answers (PanelActivity); false here. */
    open fun handlePanelCall(method: String, arguments: Any?, result: MethodChannel.Result): Boolean = false

    // -------------------------------------------------------------------------
    // Shares and shortcuts

    open fun handleIntent(intent: Intent?) {
        val launch: Map<String, Any?> = when (intent?.action) {
            MainActivity.ACTION_NEW_CHAT -> mapOf("action" to "new_chat")
            MainActivity.ACTION_VOICE -> mapOf("action" to "voice")
            MainActivity.ACTION_UPDATE -> mapOf("action" to "update")
            MainActivity.ACTION_OPEN -> Notifications.launchOf(this, intent) ?: return
            // "Tanya GripHub" without the panel (it may not show over other apps): the selection in a new chat.
            Intent.ACTION_PROCESS_TEXT -> mapOf(
                "action" to "selection",
                "text" to intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString(),
            )
            Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE -> {
                val uris = mutableListOf<Uri>()
                @Suppress("DEPRECATION")
                if (intent.action == Intent.ACTION_SEND) {
                    (intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let { uris.add(it) }
                } else {
                    intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
                }
                mapOf(
                    "action" to "share",
                    "text" to listOfNotNull(
                        intent.getStringExtra(Intent.EXTRA_SUBJECT),
                        intent.getStringExtra(Intent.EXTRA_TEXT),
                    ).joinToString("\n").ifBlank { null },
                    "files" to uris.mapNotNull { copyShared(it) },
                )
            }
            else -> return
        }
        launch(launch)
    }

    /**
     * A file safe to hand to FileProvider: inside app storage as-is, anything
     * else copied into app cache first (so shared-storage project files keep
     * working without widening the provider's roots).
     */
    private fun shareableFile(file: File): File {
        val canonical = file.canonicalFile
        val roots = listOfNotNull(filesDir?.canonicalFile, cacheDir?.canonicalFile, getExternalFilesDir(null)?.canonicalFile)
        if (roots.any { canonical == it || canonical.path.startsWith(it.path + File.separator) }) return canonical
        val dir = File(requireNotNull(cacheDir), "shared/${System.currentTimeMillis()}").apply { mkdirs() }
        val target = File(dir, canonical.name.replace('/', '_'))
        file.inputStream().use { input -> target.outputStream().use { input.copyTo(it) } }
        return target
    }

    /** Copies a shared content:// file into app cache so Flutter and the agent can read it. */
    private fun copyShared(uri: Uri): Map<String, Any?>? = try {
        // Only content:// URIs are mediated by the sender's grant. A file://
        // URI would make this app read its own private files on another
        // app's behalf (e.g. its own .ssh key) using its own privileges.
        if (uri.scheme != "content") return null
        var name = "shared"
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) name = c.getString(0) ?: name
        }
        val dir = File(cacheDir, "shared/${System.currentTimeMillis()}").apply { mkdirs() }
        val target = File(dir, name.replace('/', '_'))
        contentResolver.openInputStream(uri)?.use { input -> target.outputStream().use { input.copyTo(it) } }
        mapOf("path" to target.path, "name" to target.name, "mime" to contentResolver.getType(uri))
    } catch (e: Exception) {
        null
    }

    /** The clipboard's first item when it is a picture behind a content:// URI, else null. */
    private fun clipboardImageUri(): Uri? {
        val clipboard = getSystemService(CLIPBOARD_SERVICE) as? ClipboardManager ?: return null
        val clip = clipboard.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        val uri = clip.getItemAt(0).uri ?: return null
        // Same rule as shares: only content:// URIs, which the app that copied it grants us.
        if (uri.scheme != "content") return null
        val type = clip.description.let { d -> (0 until d.mimeTypeCount).map { d.getMimeType(it) } }
            .firstOrNull { it.startsWith("image/") } ?: contentResolver.getType(uri)
        return if (type?.startsWith("image/") == true) uri else null
    }

    /**
     * Removes copies the app made in its cache for pastes and shares once they are a day old: a chat that still needs
     * one has long since copied it into its own project (.attachments/), and Android only empties the cache when it
     * is short of space. Runs off the main thread; a failure is harmless and ignored.
     */
    private fun sweepOldCopies() {
        val cache = cacheDir ?: return
        val cutoff = System.currentTimeMillis() - OLD_COPY_MS
        Thread {
            for (name in listOf("paste", "shared", "griphub-paste")) {
                try {
                    File(cache, name).listFiles()?.filter { it.lastModified() < cutoff }?.forEach { it.deleteRecursively() }
                } catch (e: Exception) {
                    // Gone or unreadable: nothing to sweep.
                }
            }
        }.start()
    }

    /** Copies the clipboard's picture into the cache; its path, name and type, or null when it cannot be read. */
    private fun copyClipboardImage(uri: Uri): Map<String, Any?>? = try {
        val mime = contentResolver.getType(uri)?.takeIf { it.startsWith("image/") } ?: "image/png"
        val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime) ?: "png"
        val dir = File(cacheDir, "paste/${System.currentTimeMillis()}").apply { mkdirs() }
        val target = File(dir, "pasted-image.$ext")
        contentResolver.openInputStream(uri)?.use { input -> target.outputStream().use { input.copyTo(it) } }
        if (target.length() > 0) mapOf("path" to target.path, "name" to target.name, "mime" to mime) else null
    } catch (e: Exception) {
        null
    }

    /** The Play build removes MANAGE_EXTERNAL_STORAGE from its manifest; the GitHub build keeps it. */
    private fun storageAccessDeclared(): Boolean {
        if (Build.VERSION.SDK_INT < 30) return true
        @Suppress("DEPRECATION")
        val info = packageManager.getPackageInfo(packageName, PackageManager.GET_PERMISSIONS)
        return info.requestedPermissions?.contains(Manifest.permission.MANAGE_EXTERNAL_STORAGE) == true
    }

    private fun hasStorageAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= 30) Environment.isExternalStorageManager()
        else checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED

    private fun mimeOf(name: String): String =
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase())
            ?: "application/octet-stream"

    /** Copies a file into Download/GripHub and returns where it went. MediaStore needs no storage permission. */
    private fun saveToDownloads(file: File): String {
        if (Build.VERSION.SDK_INT >= 29) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, file.name)
                put(MediaStore.Downloads.MIME_TYPE, mimeOf(file.name))
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/GripHub")
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("Could not create the download")
            contentResolver.openOutputStream(uri)!!.use { out -> file.inputStream().use { it.copyTo(out) } }
        } else {
            @Suppress("DEPRECATION")
            val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "GripHub")
            dir.mkdirs()
            file.copyTo(File(dir, file.name), overwrite = true)
        }
        return "Download/GripHub/${file.name}"
    }
}
