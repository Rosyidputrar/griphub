package id.griphub.agent

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
}
