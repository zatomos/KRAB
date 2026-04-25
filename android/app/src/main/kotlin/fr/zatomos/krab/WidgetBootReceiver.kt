package fr.zatomos.krab

import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Receiver that triggers widget update after device boot or time change
 */
class WidgetBootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "WidgetBootReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_TIMEZONE_CHANGED,
            Intent.ACTION_TIME_CHANGED -> {
                Log.d(TAG, "Received action: ${intent.action}")
                
                val manager = AppWidgetManager.getInstance(context)
                val ids = manager.getAppWidgetIds(
                    ComponentName(context, HomeScreenWidget::class.java)
                )

                if (ids.isNotEmpty()) {
                    Log.d(TAG, "Updating ${ids.size} widget(s)")
                    CoroutineScope(Dispatchers.IO).launch {
                        ids.forEach { id ->
                            HomeScreenWidget.updateAppWidget(context, manager, id)
                        }
                    }
                } else {
                    Log.d(TAG, "No widgets installed")
                }
            }
        }
    }
}
