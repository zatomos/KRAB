package fr.zatomos.krab

import android.app.Application
import android.content.Context
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions

/**
 * Initialises Firebase from the per-instance config the app cached at runtime,
 * before FirebaseMessagingService can run.
 */
class KrabApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        initFirebaseFromPrefs()
    }

    private fun initFirebaseFromPrefs() {
        if (FirebaseApp.getApps(this).isNotEmpty()) return

        val prefs = getSharedPreferences(
            "FlutterSharedPreferences",
            Context.MODE_PRIVATE,
        )
        val appId = prefs.getString("flutter.fcmAppId", null)
        val apiKey = prefs.getString("flutter.fcmApiKey", null)
        val senderId = prefs.getString("flutter.fcmSenderId", null)
        val projectId = prefs.getString("flutter.fcmProjectId", null)

        // No instance config yet
        if (appId.isNullOrEmpty() || apiKey.isNullOrEmpty() ||
            senderId.isNullOrEmpty() || projectId.isNullOrEmpty()
        ) {
            return
        }

        val options = FirebaseOptions.Builder()
            .setApplicationId(appId)
            .setApiKey(apiKey)
            .setGcmSenderId(senderId)
            .setProjectId(projectId)
            .build()
        FirebaseApp.initializeApp(this, options)
    }
}
