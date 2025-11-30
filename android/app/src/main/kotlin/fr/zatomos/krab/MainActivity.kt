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
                        val showText = call.argument<Boolean>("showText") ?: false
                        handleWidgetPin(showText)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun handleWidgetPin(showText: Boolean) {
        val context = this
        val mgr = AppWidgetManager.getInstance(context)
        val widget = ComponentName(context, HomeScreenWidget::class.java)

        // Save user choice
        context.getSharedPreferences("HomeScreenWidgetPrefs", MODE_PRIVATE)
            .edit()
            .putBoolean("pending_showText", showText)
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