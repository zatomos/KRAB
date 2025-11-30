package fr.zatomos.krab

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.ImageView
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class HomeScreenWidgetConfigureActivity : Activity() {

    private var widgetId: Int = AppWidgetManager.INVALID_APPWIDGET_ID
    private var selectedShowText: Boolean? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        setResult(RESULT_CANCELED)
        widgetId = intent?.getIntExtra(
            AppWidgetManager.EXTRA_APPWIDGET_ID,
            AppWidgetManager.INVALID_APPWIDGET_ID
        ) ?: AppWidgetManager.INVALID_APPWIDGET_ID

        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }

        setContentView(R.layout.home_screen_widget_configure)

        // Get references to views
        val cardImageOnly = findViewById<View>(R.id.cardImageOnly)
        val cardImageWithText = findViewById<View>(R.id.cardImageWithText)
        val checkImageOnly = findViewById<ImageView>(R.id.checkImageOnly)
        val checkImageWithText = findViewById<ImageView>(R.id.checkImageWithText)

        // Card click listeners
        cardImageOnly.setOnClickListener {
            selectedShowText = false
            updateSelection(checkImageOnly, checkImageWithText, cardImageOnly, cardImageWithText)
            HomeScreenWidget.setShowTextPref(this, widgetId, false)
            finishSuccess()
        }

        cardImageWithText.setOnClickListener {
            selectedShowText = true
            updateSelection(checkImageWithText, checkImageOnly, cardImageWithText, cardImageOnly)
            HomeScreenWidget.setShowTextPref(this, widgetId, true)
            finishSuccess()
        }
    }

    private fun updateSelection(
        selectedCheck: ImageView,
        unselectedCheck: ImageView,
        selectedCard: View,
        unselectedCard: View
    ) {
        // Update checkmarks
        selectedCheck.setImageResource(android.R.drawable.radiobutton_on_background)
        unselectedCheck.setImageResource(android.R.drawable.radiobutton_off_background)

        // Update card backgrounds
        selectedCard.setBackgroundColor(
            ContextCompat.getColor(this, android.R.color.holo_blue_light).let {
                (it and 0x00FFFFFF) or 0x20000000
            }
        )
        unselectedCard.setBackgroundColor(
            ContextCompat.getColor(this, android.R.color.white)
        )
    }

    private fun finishSuccess() {
        val manager = AppWidgetManager.getInstance(this)

        CoroutineScope(Dispatchers.IO).launch {
            HomeScreenWidget.updateAppWidget(
                this@HomeScreenWidgetConfigureActivity,
                manager,
                widgetId
            )

            withContext(Dispatchers.Main) {
                val result = Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
                setResult(RESULT_OK, result)
                finish()
            }
        }
    }
}