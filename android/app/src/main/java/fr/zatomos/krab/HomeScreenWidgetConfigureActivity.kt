package fr.zatomos.krab

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.EditText
import fr.zatomos.krab.databinding.HomeScreenWidgetConfigureBinding
import fr.zatomos.krab.HomeScreenWidget.Companion.updateAppWidget
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The configuration screen for the [HomeScreenWidget] AppWidget.
 */
class HomeScreenWidgetConfigureActivity : Activity() {
    private var appWidgetId = AppWidgetManager.INVALID_APPWIDGET_ID
    private lateinit var appWidgetText: EditText
    private lateinit var binding: HomeScreenWidgetConfigureBinding

    private var onClickListener = View.OnClickListener {
        val context = this@HomeScreenWidgetConfigureActivity

        // When the button is clicked, store the string locally
        val widgetText = appWidgetText.text.toString()
        saveTitlePref(context, appWidgetId, widgetText)

        // Get the AppWidgetManager instance
        val appWidgetManager = AppWidgetManager.getInstance(context)

        // Launch a coroutine to call the suspend function updateAppWidget
        CoroutineScope(Dispatchers.IO).launch {
            updateAppWidget(context, appWidgetManager, appWidgetId)
            // Switch back to the main thread to finish the activity
            withContext(Dispatchers.Main) {
                val resultValue = Intent().apply {
                    putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
                }
                setResult(RESULT_OK, resultValue)
                finish()
            }
        }
    }

    public override fun onCreate(icicle: Bundle?) {
        super.onCreate(icicle)
        // Set the default result to CANCELED. This causes the widget host to cancel widget placement if the user backs out.
        setResult(RESULT_CANCELED)

        binding = HomeScreenWidgetConfigureBinding.inflate(layoutInflater)
        setContentView(binding.root)

        appWidgetText = binding.appwidgetText as EditText
        binding.addButton.setOnClickListener(onClickListener)

        // Retrieve the widget ID from the launching Intent extras.
        val intent = intent
        val extras = intent.extras
        if (extras != null) {
            appWidgetId = extras.getInt(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        }

        // If no valid widget ID was provided, finish the activity.
        if (appWidgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }

        appWidgetText.setText(loadTitlePref(this@HomeScreenWidgetConfigureActivity, appWidgetId))
    }
}

private const val PREFS_NAME = "fr.zatomos.krab.HomeScreenWidget"
private const val PREF_PREFIX_KEY = "appwidget_"

// Save the widget text in SharedPreferences.
internal fun saveTitlePref(context: Context, appWidgetId: Int, text: String) {
    val prefs = context.getSharedPreferences(PREFS_NAME, 0).edit()
    prefs.putString(PREF_PREFIX_KEY + appWidgetId, text)
    prefs.apply()
}

// Load the widget text from SharedPreferences. If not found, use the default.
internal fun loadTitlePref(context: Context, appWidgetId: Int): String {
    val prefs = context.getSharedPreferences(PREFS_NAME, 0)
    val titleValue = prefs.getString(PREF_PREFIX_KEY + appWidgetId, null)
    return titleValue ?: context.getString(R.string.appwidget_text)
}

// Remove the widget text from SharedPreferences.
internal fun deleteTitlePref(context: Context, appWidgetId: Int) {
    val prefs = context.getSharedPreferences(PREFS_NAME, 0).edit()
    prefs.remove(PREF_PREFIX_KEY + appWidgetId)
    prefs.apply()
}
