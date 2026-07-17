package fr.zatomos.krab

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
import java.io.File

class HomeScreenWidgetMulti : AppWidgetProvider() {

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, ids: IntArray) {
        HomeScreenWidget.syncRegistry(context)
        CoroutineScope(Dispatchers.IO).launch {
            ids.forEach { id -> updateAppWidget(context, appWidgetManager, id) }
        }
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        appWidgetIds.forEach { id -> HomeScreenWidget.deletePrefs(context, id) }
        HomeScreenWidget.syncRegistry(context)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == HomeScreenWidget.ACTION_IMAGE_UPDATED) {
            HomeScreenWidget.syncRegistry(context)
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, HomeScreenWidgetMulti::class.java))
            CoroutineScope(Dispatchers.IO).launch {
                ids.forEach { id -> updateAppWidget(context, manager, id) }
            }
        }
    }

    companion object {
        private const val TAG = "HomeScreenWidgetMulti"

        private fun buildBaseViews(
            context: Context,
            id: Int,
            showText: Boolean,
            showGradient: Boolean,
            showPfp: Boolean,
            showSenderName: Boolean,
            showPrevPfps: Boolean,
            descLines: Int,
            description: String?,
            sender: String?,
            tapToOpen: Boolean,
            showQuickSnap: Boolean,
            mainId: String?,
            prev1Id: String?,
            prev2Id: String?
        ): RemoteViews {
            val density = context.resources.displayMetrics.density
            fun Int.px() = (this * density).toInt()

            val views = RemoteViews(context.packageName, R.layout.home_screen_widget_multi)
            // Undo the signed-out state explicitly.
            views.setViewVisibility(R.id.signed_out_container, View.GONE)
            views.setViewVisibility(R.id.multi_main_image, View.VISIBLE)
            views.setViewVisibility(R.id.multi_prev_image1, View.VISIBLE)
            views.setViewVisibility(R.id.multi_prev_image2, View.VISIBLE)
            views.setImageViewResource(R.id.multi_main_image, R.drawable.ic_placeholder)
            views.setImageViewResource(R.id.multi_prev_image1, R.drawable.ic_placeholder)
            views.setImageViewResource(R.id.multi_prev_image2, R.drawable.ic_placeholder)
            views.setViewVisibility(R.id.overlay_pfp, View.GONE)
            views.setViewVisibility(R.id.prev_pfp_1, View.GONE)
            views.setViewVisibility(R.id.prev_pfp_2, View.GONE)

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
                    views.setInt(R.id.overlay_container, "setBackgroundResource",
                        R.drawable.widget_gradient_overlay)
                    views.setViewPadding(R.id.overlay_container, 10.px(), 24.px(), 10.px(), 8.px())
                } else {
                    views.setInt(R.id.overlay_container, "setBackgroundColor",
                        Color.parseColor("#80000000"))
                    views.setViewPadding(R.id.overlay_container, 6.px(), 6.px(), 6.px(), 6.px())
                }
                if (showPfp) views.setViewVisibility(R.id.overlay_pfp, View.VISIBLE)
            } else {
                views.setViewVisibility(R.id.overlay_container, View.GONE)
            }

            if (showPrevPfps) {
                views.setViewVisibility(R.id.prev_pfp_1, View.VISIBLE)
                views.setViewVisibility(R.id.prev_pfp_2, View.VISIBLE)
            }

            views.setOnClickPendingIntent(
                R.id.multi_main_image,
                HomeScreenWidget.imageClickIntent(context, id, tapToOpen, mainId)
            )
            views.setOnClickPendingIntent(
                R.id.multi_prev_image1,
                HomeScreenWidget.imageClickIntent(context, id or HomeScreenWidget.REQ_PREV1, tapToOpen, prev1Id)
            )
            views.setOnClickPendingIntent(
                R.id.multi_prev_image2,
                HomeScreenWidget.imageClickIntent(context, id or HomeScreenWidget.REQ_PREV2, tapToOpen, prev2Id)
            )
            HomeScreenWidget.applyQuickSnap(context, views, id, tapToOpen, showQuickSnap)
            return views
        }

        /// Draw a previous image's pfp, or hide it when the slot holds no image.
        private suspend fun applyPrevPfp(
            context: Context,
            manager: AppWidgetManager,
            views: RemoteViews,
            id: Int,
            slot: Int,
            viewId: Int,
            imageUrl: String?,
            pfpUrl: String?,
            sender: String?,
            pfpBudget: Int
        ) {
            if (imageUrl.isNullOrEmpty()) {
                views.setViewVisibility(viewId, View.GONE)
            } else {
                views.setImageViewBitmap(viewId, HomeScreenWidget.pfpBitmap(
                    context, pfpUrl, sender, HomeScreenWidget.PREV_PFP_SIZE_DP, pfpBudget))
            }
            if (!manager.tryUpdateAppWidget(context, id, views))
                Log.w(TAG, "Widget $id: prev$slot pfp exceeded bitmap limit, skipping")
        }

        suspend fun updateAppWidget(context: Context, manager: AppWidgetManager, id: Int) {
            try {
                val prefs = HomeWidgetPlugin.getData(context)
                val mainUrl = HomeScreenWidget.keyedString(prefs, "recentImageUrl", id)
                val prev1Url = HomeScreenWidget.keyedString(prefs, "previousImage1Url", id)
                val prev2Url = HomeScreenWidget.keyedString(prefs, "previousImage2Url", id)
                val sender = HomeScreenWidget.keyedString(prefs, "recentImageSender", id)
                val description = HomeScreenWidget.keyedString(prefs, "recentImageDescription", id)
                val pfpUrl = HomeScreenWidget.keyedString(prefs, "recentSenderPfpUrl", id)
                val prev1PfpUrl = HomeScreenWidget.keyedString(prefs, "previousImage1SenderPfpUrl",id)
                val prev2PfpUrl = HomeScreenWidget.keyedString(prefs, "previousImage2SenderPfpUrl", id)
                val prev1Sender = HomeScreenWidget.keyedString(prefs, "previousImage1Sender", id)
                val prev2Sender = HomeScreenWidget.keyedString(prefs, "previousImage2Sender", id)
                val mainId = HomeScreenWidget.keyedString(prefs, "lastImageId", id)
                val prev1Id = HomeScreenWidget.keyedString(prefs, "previousImage1Id", id)
                val prev2Id = HomeScreenWidget.keyedString(prefs, "previousImage2Id", id)

                val showText = HomeScreenWidget.getShowTextPref(context, id)
                val showGradient = HomeScreenWidget.getShowGradientPref(context, id)
                val showPfp = HomeScreenWidget.getShowPfpPref(context, id)
                val showSenderName = HomeScreenWidget.getShowSenderNamePref(context, id)
                val showPrevPfps = HomeScreenWidget.getShowPrevPfpsPref(context, id)
                val tapToOpen = HomeScreenWidget.getTapToOpenPref(context, id)
                val showQuickSnap = HomeScreenWidget.getShowQuickSnapPref(context, id)
                val descLines = HomeScreenWidget.getDescLinesPref(context, id, default = 1).coerceIn(1, 2)

                val pfpSlots = (if (showText && showPfp) 1 else 0) + (if (showPrevPfps) 2 else 0)

                // The session is gone, display disconnected
                if (prefs.getBoolean(HomeScreenWidget.PREF_SIGNED_OUT_KEY, false)) {
                    Log.d(TAG, "Widget $id: signed out")
                    val signedOutViews =
                        RemoteViews(context.packageName, R.layout.home_screen_widget_multi)
                    signedOutViews.setViewVisibility(R.id.multi_main_image, View.GONE)
                    signedOutViews.setViewVisibility(R.id.multi_prev_image1, View.GONE)
                    signedOutViews.setViewVisibility(R.id.multi_prev_image2, View.GONE)
                    signedOutViews.setViewVisibility(R.id.prev_pfp_1, View.GONE)
                    signedOutViews.setViewVisibility(R.id.prev_pfp_2, View.GONE)
                    signedOutViews.setViewVisibility(R.id.overlay_container, View.GONE)
                    signedOutViews.setViewVisibility(R.id.quick_snap_button, View.GONE)
                    signedOutViews.setViewVisibility(R.id.signed_out_container, View.VISIBLE)
                    signedOutViews.setOnClickPendingIntent(R.id.signed_out_container,
                        HomeScreenWidget.openAppPendingIntent(context, id))
                    manager.tryUpdateAppWidget(context, id, signedOutViews)
                    return
                }

                // Placeholder update — no bitmaps, always succeeds
                manager.tryUpdateAppWidget(context, id,
                    buildBaseViews(context, id, showText, showGradient, showPfp, showSenderName,
                        showPrevPfps, descLines, description, sender, tapToOpen, showQuickSnap,
                        mainId, prev1Id, prev2Id))

                // Try up to twice: on overflow tryUpdateAppWidget refines the limit so
                // the retry builds fresh views with a correctly-sized budget.
                for (attempt in 1..2) {
                    val safeLimit = (systemBitmapLimit() * 0.95).toInt()
                    val pfpBudget = 128 * 1024 // * 3
                    val imageBudget = safeLimit - pfpSlots * pfpBudget
                    val mainBudget = imageBudget * 60 / 100
                    val prevBudget = imageBudget * 20 / 100 // * 2
                    Log.d(TAG, "Widget $id: sysLimit=${systemBitmapLimit()} " +
                            "pfpSlots=$pfpSlots mainBudget=$mainBudget prevBudget=$prevBudget")

                    val views = buildBaseViews(context, id, showText, showGradient, showPfp,
                        showSenderName, showPrevPfps, descLines, description, sender, tapToOpen,
                        showQuickSnap, mainId, prev1Id, prev2Id)
                    var overflow = false

                    val mainBm = loadScaledBitmap(mainUrl, mainBudget)
                    if (mainBm != null) {
                        views.setImageViewBitmap(R.id.multi_main_image, mainBm)
                        if (!manager.tryUpdateAppWidget(context, id, views)) { overflow = true }
                    }

                    if (!overflow) {
                        val bm1 = loadScaledBitmap(prev1Url, prevBudget)
                        if (bm1 != null) {
                            views.setImageViewBitmap(R.id.multi_prev_image1, bm1)
                            if (!manager.tryUpdateAppWidget(context, id, views)) { overflow = true }
                        } else {
                            Log.w(TAG, "Widget $id: prev1 null - url=$prev1Url " +
                                    "fileExists=${prev1Url?.let { File(it.trim()).exists() }}")
                        }
                    }

                    if (!overflow) {
                        val bm2 = loadScaledBitmap(prev2Url, prevBudget)
                        if (bm2 != null) {
                            views.setImageViewBitmap(R.id.multi_prev_image2, bm2)
                            if (!manager.tryUpdateAppWidget(context, id, views)) { overflow = true }
                        } else {
                            Log.w(TAG, "Widget $id: prev2 null - url=$prev2Url " +
                                    "fileExists=${prev2Url?.let { File(it.trim()).exists() }}")
                        }
                    }

                    if (overflow) continue  // retry with refined limit

                    // Pfp overflows degrade gracefully
                    if (showText && showPfp) {
                        views.setImageViewBitmap(R.id.overlay_pfp, HomeScreenWidget.pfpBitmap(
                            context, pfpUrl, sender, HomeScreenWidget.PFP_SIZE_DP, pfpBudget))
                        if (!manager.tryUpdateAppWidget(context, id, views))
                            Log.w(TAG, "Widget $id: pfp exceeded bitmap limit, skipping")
                    }

                    if (showPrevPfps) {
                        applyPrevPfp(context, manager, views, id, 1,
                            R.id.prev_pfp_1, prev1Url, prev1PfpUrl, prev1Sender, pfpBudget)
                        applyPrevPfp(context, manager, views, id, 2,
                            R.id.prev_pfp_2, prev2Url, prev2PfpUrl, prev2Sender, pfpBudget)
                    }

                    break
                }
            } catch (e: Exception) {
                Log.e(TAG, "Widget $id: updateAppWidget failed", e)
            }
        }
    }
}
