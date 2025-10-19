package fr.zatomos.krab

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.drawable.BitmapDrawable
import android.util.Log
import android.widget.RemoteViews
import androidx.core.graphics.drawable.toBitmap
import coil.Coil
import coil.request.CachePolicy
import coil.request.ImageRequest
import coil.request.SuccessResult
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import es.antonborri.home_widget.HomeWidgetPlugin
import java.io.File

class HomeScreenWidget : AppWidgetProvider() {

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        CoroutineScope(Dispatchers.IO).launch {
            appWidgetIds.forEach { widgetId ->
                updateAppWidget(context, appWidgetManager, widgetId)
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == ACTION_IMAGE_UPDATED) {
            val appWidgetManager = AppWidgetManager.getInstance(context)
            val appWidgetIds = appWidgetManager.getAppWidgetIds(intent.component ?: return)
            onUpdate(context, appWidgetManager, appWidgetIds)
        }
    }

    companion object {
        const val ACTION_IMAGE_UPDATED = "fr.zatomos.krab.ACTION_IMAGE_UPDATED"
        private const val PREF_IMAGE_URL_KEY = "recentImageUrl"
        private const val TAG = "HomeScreenWidget"

        // In-memory cache variables
        private var lastLoadedImageUrl: String? = null
        private var lastLoadedBitmap: Bitmap? = null
        private var lastImageTimestamp: Long = 0L

        // Suspend function to update the widget
        suspend fun updateAppWidget(context: Context, appWidgetManager: AppWidgetManager, appWidgetId: Int) {
            val widgetData = HomeWidgetPlugin.getData(context)
            val imageUrl = widgetData.getString(PREF_IMAGE_URL_KEY, null)
            Log.d(TAG, "WidgetID $appWidgetId: Retrieved imageUrl: $imageUrl")

            val views = RemoteViews(context.packageName, R.layout.home_screen_widget).apply {
                setImageViewResource(R.id.recent_image, R.drawable.ic_placeholder)
            }

            // Launch the app from the widget when clicked
            val clickIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                addCategory(Intent.CATEGORY_LAUNCHER)
                action = Intent.ACTION_MAIN
            }
            val clickPendingIntent = PendingIntent.getActivity(
                context,
                appWidgetId,
                clickIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.recent_image, clickPendingIntent)

            // Update widget immediately with the placeholder on the main thread
            withContext(Dispatchers.Main) {
                appWidgetManager.updateAppWidget(appWidgetId, views)
            }

            if (!imageUrl.isNullOrEmpty()) {
                // Create a File object to check the last modified time
                val imageFile = File(imageUrl)
                val currentTimestamp = if (imageFile.exists()) imageFile.lastModified() else 0L

                // Check if we already have the same image loaded (based on URL and file timestamp)
                if (imageUrl == lastLoadedImageUrl && lastLoadedBitmap != null && currentTimestamp == lastImageTimestamp) {
                    withContext(Dispatchers.Main) {
                        views.setImageViewBitmap(R.id.recent_image, lastLoadedBitmap)
                        appWidgetManager.updateAppWidget(appWidgetId, views)
                        Log.d(TAG, "WidgetID $appWidgetId: Updated widget with cached image")
                    }
                    return
                }

                try {
                    val request = ImageRequest.Builder(context)
                        .data(imageUrl)
                        // Force reload the image from the file by disabling Coil's caches
                        .memoryCachePolicy(CachePolicy.DISABLED)
                        .diskCachePolicy(CachePolicy.DISABLED)
                        .build()
                    Log.d(TAG, "WidgetID $appWidgetId: Sending image request for URL: $imageUrl")
                    val result = (Coil.imageLoader(context).execute(request) as? SuccessResult)?.drawable

                    if (result != null) {
                        Log.d(TAG, "WidgetID $appWidgetId: Image loaded successfully")
                        val bitmap = (result as? BitmapDrawable)?.bitmap ?: result.toBitmap()
                        // Update cache with new image, URL, and timestamp
                        lastLoadedImageUrl = imageUrl
                        lastLoadedBitmap = bitmap
                        lastImageTimestamp = currentTimestamp
                        withContext(Dispatchers.Main) {
                            views.setImageViewBitmap(R.id.recent_image, bitmap)
                            appWidgetManager.updateAppWidget(appWidgetId, views)
                            Log.d(TAG, "WidgetID $appWidgetId: Widget updated with new image")
                        }
                    } else {
                        Log.d(TAG, "WidgetID $appWidgetId: Coil returned null drawable")
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "WidgetID $appWidgetId: Error loading image", e)
                    withContext(Dispatchers.Main) {
                        views.setImageViewResource(R.id.recent_image, R.drawable.ic_error)
                        appWidgetManager.updateAppWidget(appWidgetId, views)
                    }
                }
            } else {
                Log.d(TAG, "WidgetID $appWidgetId: imageUrl is null or empty, nothing to load")
            }
        }

        // Save the image URL and invalidate the cache so that a new image is loaded
        fun saveImageUrl(context: Context, url: String) {
            val prefs = context.getSharedPreferences("fr.zatomos.krab.WidgetPrefs", Context.MODE_PRIVATE)
            prefs.edit().putString(PREF_IMAGE_URL_KEY, url).apply()
            Log.d(TAG, "Saved image URL: $url")

            // Invalidate the in-memory cache to force a reload on next update
            lastLoadedImageUrl = null
            lastLoadedBitmap = null
            lastImageTimestamp = 0L
            Log.d(TAG, "Invalidated in-memory cache for URL: $url")

            val intent = Intent(context, HomeScreenWidget::class.java).apply {
                action = ACTION_IMAGE_UPDATED
            }
            context.sendBroadcast(intent)
        }
    }
}
