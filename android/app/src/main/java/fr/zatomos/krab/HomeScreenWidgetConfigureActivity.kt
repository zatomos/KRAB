package fr.zatomos.krab

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.CheckBox
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.TextView
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequest
import androidx.work.WorkManager
import com.google.android.material.switchmaterial.SwitchMaterial
import dev.fluttercommunity.workmanager.BackgroundWorker
import es.antonborri.home_widget.HomeWidgetPlugin
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import org.json.JSONArray

class HomeScreenWidgetConfigureActivity : Activity() {
    private var widgetId = AppWidgetManager.INVALID_APPWIDGET_ID
    private var descLines = 2
    private var isMultiWidget = false
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    // Selected group ids for this widget. Empty = all groups.
    private val selectedGroupIds = linkedSetOf<String>()

    private lateinit var switchShowText: SwitchMaterial
    private lateinit var switchSenderName: SwitchMaterial
    private lateinit var switchGradient: SwitchMaterial
    private lateinit var switchShowPfp: SwitchMaterial
    private lateinit var switchPrevPfps: SwitchMaterial
    private lateinit var rowSenderName: View
    private lateinit var rowGradient: View
    private lateinit var rowShowPfp: View
    private lateinit var rowPrevPfps: View
    private lateinit var rowDescLines: View
    private lateinit var btnDescDecrease: ImageButton
    private lateinit var btnDescIncrease: ImageButton
    private lateinit var btnConfirm: ImageButton
    private lateinit var tvDescLines: TextView
    private lateinit var groupsContainer: LinearLayout
    private lateinit var groupsEmptyHint: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        widgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) { finish(); return }

        setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))

        setContentView(R.layout.home_screen_widget_configure)

        val providerInfo = AppWidgetManager.getInstance(this).getAppWidgetInfo(widgetId)
        isMultiWidget = providerInfo?.provider?.className == HomeScreenWidgetMulti::class.java.name

        // Ensure the Dart updater can see this widget even before onUpdate fires
        HomeScreenWidget.addToRegistry(this, widgetId, isMultiWidget)

        switchShowText = findViewById(R.id.switchShowText)
        switchSenderName = findViewById(R.id.switchSenderName)
        switchGradient = findViewById(R.id.switchGradient)
        switchShowPfp = findViewById(R.id.switchShowPfp)
        switchPrevPfps = findViewById(R.id.switchPrevPfps)
        rowSenderName = findViewById(R.id.rowSenderName)
        rowGradient = findViewById(R.id.rowGradient)
        rowShowPfp = findViewById(R.id.rowShowPfp)
        rowPrevPfps = findViewById(R.id.rowPrevPfps)
        rowDescLines = findViewById(R.id.rowDescLines)
        btnDescDecrease = findViewById(R.id.btnDescDecrease)
        btnDescIncrease = findViewById(R.id.btnDescIncrease)
        btnConfirm = findViewById(R.id.btnConfirm)
        tvDescLines = findViewById(R.id.tvDescLines)
        groupsContainer = findViewById(R.id.groupsContainer)
        groupsEmptyHint = findViewById(R.id.groupsEmptyHint)

        // Load current values
        switchShowText.isChecked = HomeScreenWidget.getShowTextPref(this, widgetId)
        switchSenderName.isChecked = HomeScreenWidget.getShowSenderNamePref(this, widgetId)
        switchGradient.isChecked = HomeScreenWidget.getShowGradientPref(this, widgetId)
        switchShowPfp.isChecked = HomeScreenWidget.getShowPfpPref(this, widgetId)
        switchPrevPfps.isChecked = HomeScreenWidget.getShowPrevPfpsPref(this, widgetId)
        descLines = HomeScreenWidget.getDescLinesPref(this, widgetId, default = if (isMultiWidget) 1 else 2)
        if (isMultiWidget) descLines = descLines.coerceIn(1, 2)
        tvDescLines.text = descLines.toString()

        if (!isMultiWidget) rowPrevPfps.visibility = View.GONE

        loadSelectedGroups()
        buildGroupCheckboxes()

        updateDependentRows(switchShowText.isChecked)
        updateStepperButtons()

        findViewById<View>(R.id.rowShowText).setOnClickListener {
            switchShowText.isChecked = !switchShowText.isChecked
            HomeScreenWidget.setShowTextPref(this, widgetId, switchShowText.isChecked)
            updateDependentRows(switchShowText.isChecked)
            applyAndUpdate()
        }
        rowSenderName.setOnClickListener {
            if (!switchShowText.isChecked) return@setOnClickListener
            switchSenderName.isChecked = !switchSenderName.isChecked
            HomeScreenWidget.setShowSenderNamePref(this, widgetId, switchSenderName.isChecked)
            applyAndUpdate()
        }
        rowGradient.setOnClickListener {
            if (!switchShowText.isChecked) return@setOnClickListener
            switchGradient.isChecked = !switchGradient.isChecked
            HomeScreenWidget.setShowGradientPref(this, widgetId, switchGradient.isChecked)
            applyAndUpdate()
        }
        rowShowPfp.setOnClickListener {
            if (!switchShowText.isChecked) return@setOnClickListener
            switchShowPfp.isChecked = !switchShowPfp.isChecked
            HomeScreenWidget.setShowPfpPref(this, widgetId, switchShowPfp.isChecked)
            applyAndUpdate()
        }
        rowPrevPfps.setOnClickListener {
            switchPrevPfps.isChecked = !switchPrevPfps.isChecked
            HomeScreenWidget.setShowPrevPfpsPref(this, widgetId, switchPrevPfps.isChecked)
            applyAndUpdate()
        }
        val maxDescLines = if (isMultiWidget) 2 else 4
        btnDescDecrease.setOnClickListener {
            if (descLines <= 1) return@setOnClickListener
            descLines--
            tvDescLines.text = descLines.toString()
            HomeScreenWidget.setDescLinesPref(this, widgetId, descLines)
            updateStepperButtons()
            applyAndUpdate()
        }
        btnDescIncrease.setOnClickListener {
            if (descLines >= maxDescLines) return@setOnClickListener
            descLines++
            tvDescLines.text = descLines.toString()
            HomeScreenWidget.setDescLinesPref(this, widgetId, descLines)
            updateStepperButtons()
            applyAndUpdate()
        }

        btnConfirm.setOnClickListener {
            persistGroups()
            finish()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        scope.cancel()
    }

    // ---- Group filter ----------------------------------------------------

    private fun loadSelectedGroups() {
        val csv = HomeWidgetPlugin.getData(this).getString("widgetGroups_$widgetId", null)
        selectedGroupIds.clear()
        if (!csv.isNullOrBlank()) {
            csv.split(",").map { it.trim() }.filter { it.isNotEmpty() }.forEach { selectedGroupIds.add(it) }
        }
    }

    private fun buildGroupCheckboxes() {
        groupsContainer.removeAllViews()
        val json = HomeWidgetPlugin.getData(this).getString("cachedGroups", null)
        if (json.isNullOrBlank()) {
            groupsEmptyHint.visibility = View.VISIBLE
            return
        }
        val groups = try { JSONArray(json) } catch (e: Exception) { null }
        if (groups == null || groups.length() == 0) {
            groupsEmptyHint.visibility = View.VISIBLE
            return
        }
        groupsEmptyHint.visibility = View.GONE

        val ta = obtainStyledAttributes(intArrayOf(android.R.attr.textColorPrimary))
        val textColor = ta.getColor(0, android.graphics.Color.WHITE)
        ta.recycle()

        for (i in 0 until groups.length()) {
            val obj = groups.optJSONObject(i) ?: continue
            val gid = obj.optString("id")
            val name = obj.optString("name")
            if (gid.isEmpty()) continue

            val cb = CheckBox(this).apply {
                text = name
                textSize = 15f
                setTextColor(textColor)
                isChecked = selectedGroupIds.contains(gid)
                setPadding(paddingLeft, 20, paddingRight, 20)
                setOnCheckedChangeListener { _, checked ->
                    if (checked) selectedGroupIds.add(gid) else selectedGroupIds.remove(gid)
                }
            }
            groupsContainer.addView(
                cb,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                )
            )
        }
    }

    /// Persist the group selection and force the Dart updater to re-fetch
    private fun persistGroups() {
        val csv = selectedGroupIds.joinToString(",")
        val editor = HomeWidgetPlugin.getData(this).edit()
        if (csv.isEmpty()) {
            editor.remove("widgetGroups_$widgetId")
        } else {
            editor.putString("widgetGroups_$widgetId", csv)
        }
        // Filter changed: clear last-seen id so the next refresh re-downloads
        editor.remove("lastImageId_$widgetId")
        editor.apply()
        triggerWidgetRefresh()
    }

    // ---- Widget update helpers -------------------------------------------

    private fun applyAndUpdate() {
        val mgr = AppWidgetManager.getInstance(this)
        scope.launch {
            if (isMultiWidget) {
                HomeScreenWidgetMulti.updateAppWidget(this@HomeScreenWidgetConfigureActivity, mgr, widgetId)
            } else {
                HomeScreenWidget.updateAppWidget(this@HomeScreenWidgetConfigureActivity, mgr, widgetId)
            }
        }
    }

    /// Enqueue a one-time background task that runs the Dart widget updater.
    private fun triggerWidgetRefresh() {
        WorkManager.getInstance(this).enqueueUniqueWork(
            "widget_configure_refresh",
            ExistingWorkPolicy.REPLACE,
            OneTimeWorkRequest.Builder(BackgroundWorker::class.java)
                .setInputData(Data.Builder().putString(BackgroundWorker.DART_TASK_KEY, "widgetPeriodicRefresh").build())
                .build()
        )
    }

    private fun updateDependentRows(showText: Boolean) {
        val alpha = if (showText) 1f else 0.4f
        rowSenderName.alpha = alpha
        rowGradient.alpha = alpha
        rowShowPfp.alpha = alpha
        rowDescLines.alpha = alpha
        switchSenderName.isEnabled = showText
        switchGradient.isEnabled = showText
        switchShowPfp.isEnabled = showText
    }

    private fun updateStepperButtons() {
        val maxDescLines = if (isMultiWidget) 2 else 4
        btnDescDecrease.alpha = if (descLines > 1) 1f else 0.3f
        btnDescIncrease.alpha = if (descLines < maxDescLines) 1f else 0.3f
    }
}
