package fr.zatomos.krab

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin
import kotlinx.coroutines.*

class HomeScreenWidget : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        ids: IntArray
    ) {
        syncRegistry(context)
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
        syncRegistry(context)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)

        if (intent.action == ACTION_IMAGE_UPDATED) {
            syncRegistry(context)
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
        private const val PREF_PFP_URL_KEY = "recentSenderPfpUrl"

        // Registry keys (written into HomeWidgetPlugin prefs, read by Dart)
        private const val REGISTRY_SINGLE_KEY = "widgetRegistrySingle"
        private const val REGISTRY_MULTI_KEY = "widgetRegistryMulti"

        fun keyedString(prefs: android.content.SharedPreferences, base: String, id: Int): String? =
            prefs.getString("${base}_$id", null)

        /// Manually add a single widget id to the registry
        fun addToRegistry(context: Context, id: Int, isMulti: Boolean) {
            val key = if (isMulti) REGISTRY_MULTI_KEY else REGISTRY_SINGLE_KEY
            val p = HomeWidgetPlugin.getData(context)
            val ids = p.getString(key, "").orEmpty()
                .split(",").mapNotNull { it.trim().toIntOrNull() }.toMutableSet()
            ids.add(id)
            p.edit().putString(key, ids.joinToString(",")).apply()
        }

        /// Write the current set of installed widget ids for both providers into
        /// HomeWidgetPlugin prefs so the Dart updater can enumerate them reliably
        fun syncRegistry(context: Context) {
            try {
                val mgr = AppWidgetManager.getInstance(context)
                val singleIds = mgr.getAppWidgetIds(ComponentName(context, HomeScreenWidget::class.java))
                val multiIds = mgr.getAppWidgetIds(ComponentName(context, HomeScreenWidgetMulti::class.java))
                HomeWidgetPlugin.getData(context).edit()
                    .putString(REGISTRY_SINGLE_KEY, singleIds.joinToString(","))
                    .putString(REGISTRY_MULTI_KEY, multiIds.joinToString(","))
                    .apply()
                Log.d(TAG, "Registry synced: single=${singleIds.toList()} multi=${multiIds.toList()}")
            } catch (e: Exception) {
                Log.e(TAG, "Registry sync failed", e)
            }
        }

        private const val PREFS_NAME = "HomeScreenWidgetPrefs"
        private const val PREF_SHOW_TEXT_PREFIX = "showText_"
        private const val PREF_SHOW_GRADIENT_PREFIX = "showGradient_"
        private const val PREF_SHOW_PFP_PREFIX = "showPfp_"
        private const val PREF_DESC_LINES_PREFIX = "descLines_"
        private const val PREF_SHOW_SENDER_NAME_PREFIX = "showSenderName_"
        private const val PREF_SHOW_PREV_PFPS_PREFIX = "showPrevPfps_"

        private fun prefs(context: Context) =
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        fun getShowTextPref(context: Context, id: Int) =
            prefs(context).getBoolean(PREF_SHOW_TEXT_PREFIX + id, false)

        fun setShowTextPref(context: Context, id: Int, value: Boolean) {
            prefs(context).edit().putBoolean(PREF_SHOW_TEXT_PREFIX + id, value).apply()
        }

        fun getShowGradientPref(context: Context, id: Int) =
            prefs(context).getBoolean(PREF_SHOW_GRADIENT_PREFIX + id, true)

        fun setShowGradientPref(context: Context, id: Int, value: Boolean) {
            prefs(context).edit().putBoolean(PREF_SHOW_GRADIENT_PREFIX + id, value).apply()
        }

        fun getShowPfpPref(context: Context, id: Int) =
            prefs(context).getBoolean(PREF_SHOW_PFP_PREFIX + id, false)

        fun setShowPfpPref(context: Context, id: Int, value: Boolean) {
            prefs(context).edit().putBoolean(PREF_SHOW_PFP_PREFIX + id, value).apply()
        }

        fun getDescLinesPref(context: Context, id: Int, default: Int = 2) =
            prefs(context).getInt(PREF_DESC_LINES_PREFIX + id, default)

        fun setDescLinesPref(context: Context, id: Int, value: Int) {
            prefs(context).edit().putInt(PREF_DESC_LINES_PREFIX + id, value.coerceIn(1, 4)).apply()
        }

        fun getShowPrevPfpsPref(context: Context, id: Int) =
            prefs(context).getBoolean(PREF_SHOW_PREV_PFPS_PREFIX + id, false)

        fun setShowPrevPfpsPref(context: Context, id: Int, value: Boolean) {
            prefs(context).edit().putBoolean(PREF_SHOW_PREV_PFPS_PREFIX + id, value).apply()
        }

        fun getShowSenderNamePref(context: Context, id: Int) =
            prefs(context).getBoolean(PREF_SHOW_SENDER_NAME_PREFIX + id, true)

        fun setShowSenderNamePref(context: Context, id: Int, value: Boolean) {
            prefs(context).edit().putBoolean(PREF_SHOW_SENDER_NAME_PREFIX + id, value).apply()
        }

        fun deletePrefs(context: Context, id: Int) {
            prefs(context).edit()
                .remove(PREF_SHOW_TEXT_PREFIX + id)
                .remove(PREF_SHOW_GRADIENT_PREFIX + id)
                .remove(PREF_SHOW_PFP_PREFIX + id)
                .remove(PREF_DESC_LINES_PREFIX + id)
                .remove(PREF_SHOW_SENDER_NAME_PREFIX + id)
                .remove(PREF_SHOW_PREV_PFPS_PREFIX + id)
                .apply()
            HomeWidgetPlugin.getData(context).edit()
                .remove("widgetGroups_$id")
                .remove("lastImageId_$id")
                .remove("recentImageUrl_$id")
                .remove("recentImageDescription_$id")
                .remove("recentImageSender_$id")
                .remove("recentSenderUserId_$id")
                .remove("recentSenderPfpUrl_$id")
                .remove("previousImage1Url_$id")
                .remove("previousImage2Url_$id")
                .remove("previousImage1SenderPfpUrl_$id")
                .remove("previousImage2SenderPfpUrl_$id")
                .apply()
        }

        suspend fun updateAppWidget(
            context: Context,
            manager: AppWidgetManager,
            id: Int
        ) {
            try {
                val prefs = HomeWidgetPlugin.getData(context)

                val imageUrl = keyedString(prefs, PREF_IMAGE_URL_KEY, id)
                val description = keyedString(prefs, PREF_IMAGE_DESC_KEY, id)
                val sender = keyedString(prefs, PREF_IMAGE_SENDER_KEY, id)
                val pfpUrl = keyedString(prefs, PREF_PFP_URL_KEY, id)

                val showText = getShowTextPref(context, id)
                val showGradient = getShowGradientPref(context, id)
                val showPfp = getShowPfpPref(context, id)
                val showSenderName = getShowSenderNamePref(context, id)
                val descLines = getDescLinesPref(context, id)

                Log.d(TAG, "Widget $id: imageUrl=$imageUrl pfpUrl=$pfpUrl showText=$showText showGradient=$showGradient showPfp=$showPfp showSenderName=$showSenderName")

                val views = RemoteViews(context.packageName, R.layout.home_screen_widget)
                views.setImageViewResource(R.id.recent_image, R.drawable.ic_placeholder)
                views.setViewVisibility(R.id.overlay_pfp, View.GONE)

                val density = context.resources.displayMetrics.density
                fun Int.px() = (this * density).toInt()

                if (showText) {
                    views.setViewVisibility(R.id.overlay_container, View.VISIBLE)

                    if (showSenderName && !sender.isNullOrEmpty()) {
                        views.setViewVisibility(R.id.overlay_sender, View.VISIBLE)
                        views.setTextViewText(R.id.overlay_sender, sender)
                    } else {
                        views.setViewVisibility(R.id.overlay_sender, View.GONE)
                    }

                    if (!description.isNullOrEmpty()) {
                        views.setViewVisibility(R.id.overlay_description, View.VISIBLE)
                        views.setTextViewText(R.id.overlay_description, description)
                        views.setInt(R.id.overlay_description, "setMaxLines", descLines)
                    } else {
                        views.setViewVisibility(R.id.overlay_description, View.GONE)
                    }

                    if (showGradient) {
                        views.setInt(R.id.overlay_container, "setBackgroundResource", R.drawable.widget_gradient_overlay)
                        views.setViewPadding(R.id.overlay_container, 10.px(), 56.px(), 10.px(), 10.px())
                    } else {
                        views.setInt(R.id.overlay_container, "setBackgroundColor", Color.parseColor("#80000000"))
                        views.setViewPadding(R.id.overlay_container, 6.px(), 6.px(), 6.px(), 6.px())
                    }

                    if (showPfp) views.setViewVisibility(R.id.overlay_pfp, View.VISIBLE)
                } else {
                    views.setViewVisibility(R.id.overlay_container, View.GONE)
                }

                val clickIntent = Intent(context, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                    addCategory(Intent.CATEGORY_LAUNCHER)
                    action = Intent.ACTION_MAIN
                }
                val pending = PendingIntent.getActivity(
                    context, id, clickIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                views.setOnClickPendingIntent(R.id.recent_image, pending)

                withContext(Dispatchers.Main) {
                    manager.updateAppWidget(id, views)
                }

                if (imageUrl.isNullOrEmpty()) {
                    Log.w(TAG, "Widget $id: no image URL saved yet")
                    return
                }

                val safeLimit = (systemBitmapLimit(context) * 0.95).toInt()
                val pfpSlots = if (showText && showPfp) 1 else 0
                val pfpBudget = safeLimit / 14  // 7% each
                val mainBudget = safeLimit - pfpSlots * pfpBudget
                val bitmap = loadScaledBitmap(imageUrl, mainBudget)
                withContext(Dispatchers.Main) {
                    if (bitmap != null) {
                        views.setImageViewBitmap(R.id.recent_image, bitmap)
                    } else {
                        views.setImageViewResource(R.id.recent_image, R.drawable.ic_error)
                    }
                    manager.updateAppWidget(id, views)
                }

                if (showText && showPfp) {
                    val pfpBitmap = loadScaledBitmap(pfpUrl, pfpBudget)
                    if (pfpBitmap != null) {
                        val circular = pfpBitmap.toCircular()
                        pfpBitmap.recycle()
                        withContext(Dispatchers.Main) {
                            views.setImageViewBitmap(R.id.overlay_pfp, circular)
                            manager.updateAppWidget(id, views)
                        }
                    } else {
                        // pfp unavailable, hide so it doesn't render blank
                        withContext(Dispatchers.Main) {
                            views.setViewVisibility(R.id.overlay_pfp, View.GONE)
                            manager.updateAppWidget(id, views)
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Widget $id: updateAppWidget failed", e)
            }
        }
    }
}
