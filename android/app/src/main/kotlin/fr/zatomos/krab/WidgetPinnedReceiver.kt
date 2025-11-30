package fr.zatomos.krab

import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.ComponentName
import android.content.Intent
import android.util.Log
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

class WidgetPinnedReceiver : BroadcastReceiver() {

    companion object {
        private const val EVENTS_CHANNEL = "krab/widget_pin_events"
    }

    override fun onReceive(context: Context, intent: Intent) {
        Log.d("WidgetPinnedReceiver", "Received widget pinned callback")

        val mgr = AppWidgetManager.getInstance(context)
        val widget = ComponentName(context, HomeScreenWidget::class.java)
        val prefs = context.getSharedPreferences("HomeScreenWidgetPrefs", Context.MODE_PRIVATE)

        // Try to get widget ID from intent extras first
        var appWidgetId = intent.getIntExtra(
            AppWidgetManager.EXTRA_APPWIDGET_ID,
            AppWidgetManager.INVALID_APPWIDGET_ID
        )

        // If not in extras, find it by comparing old vs new IDs
        if (appWidgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            Log.d("WidgetPinnedReceiver", "Widget ID not in extras, finding manually...")

            val oldIds = prefs.getStringSet("old_widget_ids", emptySet())
                ?.mapNotNull { it.toIntOrNull() }
                ?.toSet() ?: emptySet()

            val currentIds = mgr.getAppWidgetIds(widget).toSet()
            val newIds = currentIds - oldIds

            if (newIds.isNotEmpty()) {
                appWidgetId = newIds.first()
                Log.d("WidgetPinnedReceiver", "Found new widget ID manually: $appWidgetId")
            }
        }

        if (appWidgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            Log.w("WidgetPinnedReceiver", "Could not determine widget ID")
            return
        }

        Log.d("WidgetPinnedReceiver", "Processing widget ID = $appWidgetId")

        val showText = prefs.getBoolean("pending_showText", false)

        // Apply showText preference
        HomeScreenWidget.setShowTextPref(context, appWidgetId, showText)

        // Update widget UI
        CoroutineScope(Dispatchers.IO).launch {
            HomeScreenWidget.updateAppWidget(context, mgr, appWidgetId)
        }

        // Notify Flutter
        try {
            val engine = FlutterEngineCache.getInstance()["main"]
            if (engine != null) {
                val channel = MethodChannel(engine.dartExecutor.binaryMessenger, EVENTS_CHANNEL)
                channel.invokeMethod("onWidgetPinned", null)
                Log.d("WidgetPinnedReceiver", "Flutter notified: widget pinned")
            } else {
                Log.w("WidgetPinnedReceiver", "No Flutter engine found in cache")
            }
        } catch (e: Exception) {
            Log.e("WidgetPinnedReceiver", "Error sending callback to Flutter", e)
        }
    }
}