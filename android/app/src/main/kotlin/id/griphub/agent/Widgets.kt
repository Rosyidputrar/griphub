package id.griphub.agent

import android.app.Activity
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject
import java.text.DateFormat
import java.util.Date

/**
 * The two home-screen widgets (Fitur 7): "Tanya Cepat" (ask in one tap) and "Status Agent" (what is going on now).
 *
 * What they show comes from the app's real state: Flutter sends a snapshot (widgetState) whenever the chat, jobs,
 * subagents, approvals, schedules or credits change, with its texts already in the app's language; it is kept here and
 * drawn. Nothing polls: besides those pushes, Android's minimum refresh (30 minutes) redraws the last snapshot, which
 * then says when it was taken. A tap only ever opens something; nothing paid or risky starts from a widget.
 */
object WidgetState {
    private const val PREFS = "widgets"
    private const val KEY = "snapshot"

    fun save(context: Context, json: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY, json).apply()
        redrawAll(context)
    }

    fun load(context: Context): JSONObject = try {
        JSONObject(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null) ?: "{}")
    } catch (e: Exception) {
        JSONObject()
    }

    fun redrawAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        for (cls in listOf(AskWidget::class.java, StatusWidget::class.java)) {
            val ids = manager.getAppWidgetIds(ComponentName(context, cls))
            if (ids.isEmpty()) continue
            for (id in ids) {
                val views = if (cls == AskWidget::class.java) AskWidget.views(context, manager, id) else StatusWidget.views(context, manager, id)
                manager.updateAppWidget(id, views)
            }
        }
    }

    /** The app's theme as the snapshot says (light or dark), else the phone's. */
    fun dark(context: Context, s: JSONObject): Boolean = if (s.has("dark")) s.optBoolean("dark") else
        (context.resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK) == android.content.res.Configuration.UI_MODE_NIGHT_YES

    fun colors(dark: Boolean) = if (dark) Triple(0xFFF2F2F5.toInt(), 0x99F2F2F5.toInt(), 0xFF16161A.toInt())
    else Triple(0xFF111113.toInt(), 0x99111113.toInt(), 0xFFF7F7F8.toInt())

    /** Opens the app with [launch] (the notifications' own safe way in: a per-install token). */
    fun open(context: Context, code: Int, launch: Map<String, Any?>?): PendingIntent = Notifications.openIntent(context, code, launch, "widget")

    fun map(o: JSONObject?): Map<String, Any?>? =
        o?.keys()?.asSequence()?.associateWith { k -> o.opt(k).takeUnless { it == JSONObject.NULL } }
}

/** Taps of "Tanya Cepat" land here: the panel when it may show over other apps (checked now), else the app. */
class WidgetActionActivity : Activity() {
    companion object {
        const val EXTRA_WHAT = "what"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        when (intent.getStringExtra(EXTRA_WHAT)) {
            // The model's mark: the app, at the model picker.
            "model" -> startActivity(appWith(mapOf("action" to "pick_model")))
            "voice" -> if (!Overlay.openPanel(this, Intent(PanelActivity.ACTION_VOICE))) {
                startActivity(Intent(this, MainActivity::class.java).setAction(MainActivity.ACTION_VOICE).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP))
            }
            else -> if (!Overlay.openPanel(this, null)) startActivity(appWith(mapOf("action" to "new_plain_chat")))
        }
        finish()
    }

    private fun appWith(launch: Map<String, Any?>): Intent = Intent(this, MainActivity::class.java)
        .setAction(MainActivity.ACTION_OPEN)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        .putExtra(Notifications.EXTRA_LAUNCH, JSONObject(launch).toString())
        .putExtra(Notifications.EXTRA_TOKEN, Notifications.token(this))
}

/** "Tanya Cepat": a composer-like row. No real text field: a widget cannot take typing, and it does not pretend to. */
class AskWidget : AppWidgetProvider() {
    companion object {
        fun views(context: Context, manager: AppWidgetManager, id: Int): RemoteViews {
            val s = WidgetState.load(context)
            val dark = WidgetState.dark(context, s)
            val (fg, muted, _) = WidgetState.colors(dark)
            val narrow = manager.getAppWidgetOptions(id).getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 250) < 200
            return RemoteViews(context.packageName, R.layout.widget_ask).apply {
                setInt(R.id.ask_root, "setBackgroundResource", if (dark) R.drawable.widget_card_dark else R.drawable.widget_card_light)
                setInt(R.id.ask_field, "setBackgroundResource", if (dark) R.drawable.widget_field_dark else R.drawable.widget_field_light)
                setTextViewText(R.id.ask_hint, s.optString("askHint", "Tanya apa saja…"))
                setTextColor(R.id.ask_hint, muted)
                val model = s.optString("model", "")
                setTextViewText(R.id.ask_model, model)
                setTextColor(R.id.ask_model, muted)
                setViewVisibility(R.id.ask_model, if (model.isBlank() || narrow) View.GONE else View.VISIBLE)
                setInt(R.id.ask_mic, "setColorFilter", fg)
                setInt(R.id.ask_send, "setColorFilter", fg)
                // On the smallest size the row keeps the mark, the field and Send.
                setViewVisibility(R.id.ask_mic, if (narrow) View.GONE else View.VISIBLE)
                setOnClickPendingIntent(R.id.ask_field, tap(context, "ask", 51))
                setOnClickPendingIntent(R.id.ask_send, tap(context, "ask", 52))
                setOnClickPendingIntent(R.id.ask_mic, tap(context, "voice", 53))
                setOnClickPendingIntent(R.id.ask_model_icon, tap(context, "model", 54))
                setContentDescription(R.id.ask_model_icon, s.optString("modelLabel", "Model"))
                setContentDescription(R.id.ask_mic, s.optString("voiceLabel", "Voice"))
                setContentDescription(R.id.ask_send, s.optString("askLabel", "Ask"))
            }
        }

        private fun tap(context: Context, what: String, code: Int): PendingIntent = PendingIntent.getActivity(
            context, code,
            Intent(context, WidgetActionActivity::class.java).putExtra(WidgetActionActivity.EXTRA_WHAT, what).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) manager.updateAppWidget(id, views(context, manager, id))
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, newOptions: Bundle) {
        manager.updateAppWidget(id, views(context, manager, id))
    }
}

/** "Status Agent": credits and model, then what is going on (3 rows at 4x2, more when taller), or a calm empty state. */
class StatusWidget : AppWidgetProvider() {
    companion object {
        private val ROWS = intArrayOf(R.id.st_row_0, R.id.st_row_1, R.id.st_row_2, R.id.st_row_3, R.id.st_row_4, R.id.st_row_5)
        private val ICONS = intArrayOf(R.id.st_icon_0, R.id.st_icon_1, R.id.st_icon_2, R.id.st_icon_3, R.id.st_icon_4, R.id.st_icon_5)
        private val TITLES = intArrayOf(R.id.st_title_0, R.id.st_title_1, R.id.st_title_2, R.id.st_title_3, R.id.st_title_4, R.id.st_title_5)
        private val SUBS = intArrayOf(R.id.st_sub_0, R.id.st_sub_1, R.id.st_sub_2, R.id.st_sub_3, R.id.st_sub_4, R.id.st_sub_5)

        /** A snapshot older than this says when it was taken (the app may be closed, the agent stopped). */
        private const val STALE_MS = 15L * 60 * 1000

        private fun icon(kind: String) = when (kind) {
            "session" -> R.drawable.ic_w_chat
            "job" -> R.drawable.ic_w_job
            "subagent" -> R.drawable.ic_w_bot
            "schedule" -> R.drawable.ic_w_clock
            else -> R.drawable.ic_w_check
        }

        fun views(context: Context, manager: AppWidgetManager, id: Int): RemoteViews {
            val s = WidgetState.load(context)
            val dark = WidgetState.dark(context, s)
            val (fg, muted, _) = WidgetState.colors(dark)
            val tall = manager.getAppWidgetOptions(id).getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 110) >= 220
            val room = if (tall) ROWS.size else 3
            return RemoteViews(context.packageName, R.layout.widget_status).apply {
                setInt(R.id.st_root, "setBackgroundResource", if (dark) R.drawable.widget_card_dark else R.drawable.widget_card_light)
                setTextViewText(R.id.st_credits, s.optString("credits", ""))
                setTextColor(R.id.st_credits, fg)
                setTextViewText(R.id.st_model, s.optString("model", ""))
                setTextColor(R.id.st_model, muted)
                setOnClickPendingIntent(R.id.st_header, WidgetState.open(context, 60, mapOf("action" to "open_usage")))
                // The one signal that stands out: approvals waiting for the user.
                val approvals = s.optInt("approvals", 0)
                setViewVisibility(R.id.st_badge, if (approvals > 0) View.VISIBLE else View.GONE)
                setTextViewText(R.id.st_badge, approvals.toString())
                setContentDescription(R.id.st_badge, s.optString("approvalsLabel", ""))
                setOnClickPendingIntent(R.id.st_badge, WidgetState.open(context, 61, WidgetState.map(s.optJSONObject("approvalsLaunch"))))
                val rows = s.optJSONArray("rows")
                val count = minOf(rows?.length() ?: 0, room)
                for (i in ROWS.indices) {
                    if (i >= count) {
                        setViewVisibility(ROWS[i], View.GONE)
                        continue
                    }
                    val r = rows!!.getJSONObject(i)
                    setViewVisibility(ROWS[i], View.VISIBLE)
                    setImageViewResource(ICONS[i], icon(r.optString("kind")))
                    setInt(ICONS[i], "setColorFilter", fg)
                    setTextViewText(TITLES[i], r.optString("title"))
                    setTextColor(TITLES[i], fg)
                    // Secondary lines: one quiet colour, all of them.
                    setTextViewText(SUBS[i], r.optString("sub"))
                    setTextColor(SUBS[i], muted)
                    setViewVisibility(SUBS[i], if (r.optString("sub").isBlank()) View.GONE else View.VISIBLE)
                    setOnClickPendingIntent(ROWS[i], WidgetState.open(context, 70 + i, WidgetState.map(r.optJSONObject("launch"))))
                }
                val empty = count == 0
                setViewVisibility(R.id.st_empty, if (empty) View.VISIBLE else View.GONE)
                setTextViewText(R.id.st_empty, s.optString("empty", "Tidak ada yang berjalan"))
                setTextColor(R.id.st_empty, fg)
                val next = s.optString("emptySub", "")
                setViewVisibility(R.id.st_empty_sub, if (empty && next.isNotBlank()) View.VISIBLE else View.GONE)
                setTextViewText(R.id.st_empty_sub, next)
                setTextColor(R.id.st_empty_sub, muted)
                setOnClickPendingIntent(R.id.st_empty, WidgetState.open(context, 62, mapOf("action" to "open_tasks")))
                val at = s.optLong("at", 0)
                val stale = at > 0 && System.currentTimeMillis() - at > STALE_MS
                setViewVisibility(R.id.st_updated, if (stale) View.VISIBLE else View.GONE)
                setTextViewText(R.id.st_updated, s.optString("updatedLabel", "Updated {time}").replace("{time}", DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(at))))
                setTextColor(R.id.st_updated, muted)
            }
        }
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) manager.updateAppWidget(id, views(context, manager, id))
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, newOptions: Bundle) {
        manager.updateAppWidget(id, views(context, manager, id))
    }
}
