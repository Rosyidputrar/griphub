package id.griphub.agent

import io.flutter.embedding.engine.FlutterEngine

/** The app's main window: the whole app, and what the rest of Android sends it (shares, shortcuts, notifications). */
class MainActivity : BridgeActivity() {
    companion object {
        const val ACTION_NEW_CHAT = "id.griphub.agent.NEW_CHAT"
        const val ACTION_VOICE = "id.griphub.agent.VOICE"
        const val ACTION_UPDATE = "id.griphub.agent.UPDATE"
        /** A notification tap; the launch map rides along (Notifications.kt). */
        const val ACTION_OPEN = "id.griphub.agent.OPEN"
    }

    override val surface = "app"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Updater.register(this, flutterEngine.dartExecutor.binaryMessenger)
    }
}
