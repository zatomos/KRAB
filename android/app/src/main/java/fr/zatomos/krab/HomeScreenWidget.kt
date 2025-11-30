package fr.zatomos.krab

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin
import kotlinx.coroutines.*
import java.io.File

class HomeScreenWidget : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        ids: IntArray
    ) {
        CoroutineScope(Dispatchers.IO).launch {
            ids.forEach { id ->
                updateAppWidget(context, appWidgetManager, id)
            }
        }
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        appWidgetIds.forEach { id ->
            deletePrefs(context, id)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)

        if (intent.action == ACTION_IMAGE_UPDATED) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(
                ComponentName(context, HomeScreenWidget::class.java)
            )

            CoroutineScope(Dispatchers.IO).launch {
                ids.forEach { id ->
                    updateAppWidget(context, manager, id)
                }
            }
        }
    }

    companion object {
        const val ACTION_IMAGE_UPDATED = "fr.zatomos.krab.ACTION_IMAGE_UPDATED"
        private const val TAG = "HomeScreenWidget"

        private const val PREF_IMAGE_URL_KEY = "recentImageUrl"
        private const val PREF_IMAGE_DESC_KEY = "recentImageDescription"
        private const val PREF_IMAGE_SENDER_KEY = "recentImageSender"

        private const val PREFS_NAME = "HomeScreenWidgetPrefs"
        private const val PREF_SHOW_TEXT_PREFIX = "showText_"

        private fun getShowTextPref(context: Context, id: Int): Boolean {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            return prefs.getBoolean(PREF_SHOW_TEXT_PREFIX + id, false)
        }

        fun setShowTextPref(context: Context, id: Int, show: Boolean) {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            prefs.edit().putBoolean(PREF_SHOW_TEXT_PREFIX + id, show).apply()
        }

        fun deletePrefs(context: Context, id: Int) {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            prefs.edit().remove(PREF_SHOW_TEXT_PREFIX + id).apply()
        }

        suspend fun updateAppWidget(
            context: Context,
            manager: AppWidgetManager,
            id: Int
        ) {
            val prefs = HomeWidgetPlugin.getData(context)

            val imageUrl = prefs.getString(PREF_IMAGE_URL_KEY, null)
            val description = prefs.getString(PREF_IMAGE_DESC_KEY, null)
            val sender = prefs.getString(PREF_IMAGE_SENDER_KEY, null)

            val showText = getShowTextPref(context, id)

            Log.d(TAG, "WidgetID $id update. imageUrl=$imageUrl desc=$description sender=$sender showText=$showText")

            val views = RemoteViews(context.packageName, R.layout.home_screen_widget)

            // Placeholder
            views.setImageViewResource(R.id.recent_image, R.drawable.ic_placeholder)

            // Overlay text
            if (showText && !description.isNullOrEmpty() && !sender.isNullOrEmpty()) {
                views.setViewVisibility(R.id.overlay_text, View.VISIBLE)
                views.setTextViewText(R.id.overlay_text, "$sender: $description")
            } else {
                views.setViewVisibility(R.id.overlay_text, View.GONE)
            }

            // Click to open app
            val clickIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                addCategory(Intent.CATEGORY_LAUNCHER)
                action = Intent.ACTION_MAIN
            }

            val pending = PendingIntent.getActivity(
                context,
                id,
                clickIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.recent_image, pending)

            // Show placeholder first
            withContext(Dispatchers.Main) {
                manager.updateAppWidget(id, views)
            }

            if (imageUrl.isNullOrEmpty()) {
                Log.d(TAG, "WidgetID $id: no image URL → done")
                return
            }

            try {
                val file = File(imageUrl)
                if (!file.exists()) {
                    Log.w(TAG, "WidgetID $id: image file does not exist: $imageUrl")
                    return
                }

                val bitmap = BitmapFactory.decodeFile(file.absolutePath)

                if (bitmap != null) {
                    withContext(Dispatchers.Main) {
                        views.setImageViewBitmap(R.id.recent_image, bitmap)
                        manager.updateAppWidget(id, views)
                    }
                } else {
                    Log.e(TAG, "WidgetID $id: BitmapFactory.decodeFile returned null")
                    withContext(Dispatchers.Main) {
                        views.setImageViewResource(R.id.recent_image, R.drawable.ic_error)
                        manager.updateAppWidget(id, views)
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "WidgetID $id: error loading image", e)
                withContext(Dispatchers.Main) {
                    views.setImageViewResource(R.id.recent_image, R.drawable.ic_error)
                    manager.updateAppWidget(id, views)
                }
            }
        }
    }
}
