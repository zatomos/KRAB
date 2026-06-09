package fr.zatomos.krab

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "krab/widget_pin"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Cache engine so the receiver can access it
        FlutterEngineCache
            .getInstance()
            .put("main", flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pinWidget" -> {
                        val multi = call.argument<Boolean>("multi") ?: false
                        handleWidgetPin(multi)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun handleWidgetPin(multi: Boolean) {
        val context = this
        val mgr = AppWidgetManager.getInstance(context)
        val widget = if (multi)
            ComponentName(context, HomeScreenWidgetMulti::class.java)
        else
            ComponentName(context, HomeScreenWidget::class.java)

        // Remember which provider we requested and its existing ids, so the
        // pinned callback can identify the newly added widget and update the
        // matching provider
        context.getSharedPreferences("HomeScreenWidgetPrefs", MODE_PRIVATE)
            .edit()
            .putBoolean("pending_multi", multi)
            .putStringSet(
                "old_widget_ids",
                mgr.getAppWidgetIds(widget).map { it.toString() }.toSet()
            )
            .apply()

        // Create bundle with widget configuration
        val configBundle = Bundle().apply {}

        // Callback when done
        val callbackIntent = Intent(context, WidgetPinnedReceiver::class.java)

        val callback = PendingIntent.getBroadcast(
            context,
            0,
            callbackIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE // Changed to MUTABLE!
        )

        // Request pinning
        mgr.requestPinAppWidget(widget, configBundle, callback)
    }
}