package fr.zatomos.krab

import android.app.Application
import android.content.Context
import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import org.json.JSONArray

/**
 * Initialises Firebase from the per-instance config the app cached at runtime,
 * before FirebaseMessagingService can run.
 *
 * The instance list is written by Dart's InstanceRegistry as a JSON array under
 * `flutter.krab_instances`. This reads it here rather than taking the four FCM
 * values from flat prefs, because a push can arrive while the app is dead and
 * the config has to be found without running any Dart.
 *
 * Only one FirebaseApp is brought up, from the first instance that published an
 * FCM config. Serving several senders at once needs a secondary FirebaseApp per
 * instance, which is phase 2.
 */
class KrabApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        initFirebaseFromPrefs()
    }

    private fun initFirebaseFromPrefs() {
        if (FirebaseApp.getApps(this).isNotEmpty()) return

        val options = firstInstanceWithFcm() ?: return
        FirebaseApp.initializeApp(this, options)
    }

    /** The FCM config of the first connected instance that has one. */
    private fun firstInstanceWithFcm(): FirebaseOptions? {
        val prefs = getSharedPreferences(
            "FlutterSharedPreferences",
            Context.MODE_PRIVATE,
        )
        val raw = prefs.getString("flutter.$INSTANCES_KEY", null)
        if (raw.isNullOrEmpty()) return null

        return try {
            val instances = JSONArray(raw)
            for (i in 0 until instances.length()) {
                val config = instances.optJSONObject(i)?.optJSONObject("config")
                    ?: continue

                val appId = config.optString("fcm_app_id")
                val apiKey = config.optString("fcm_api_key")
                val senderId = config.optString("fcm_sender_id")
                val projectId = config.optString("fcm_project_id")

                // An instance whose config hasn't been fetched yet.
                if (appId.isEmpty() || apiKey.isEmpty() ||
                    senderId.isEmpty() || projectId.isEmpty()
                ) {
                    continue
                }

                return FirebaseOptions.Builder()
                    .setApplicationId(appId)
                    .setApiKey(apiKey)
                    .setGcmSenderId(senderId)
                    .setProjectId(projectId)
                    .build()
            }
            null
        } catch (e: Exception) {
            // A push we cannot show beats a launch crash.
            Log.w(TAG, "Could not read the instance list", e)
            null
        }
    }

    private companion object {
        const val TAG = "KrabApplication"

        /** Must match InstanceRegistry.prefsKey on the Dart side. */
        const val INSTANCES_KEY = "krab_instances"
    }
}
