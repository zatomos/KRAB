package fr.zatomos.krab

import android.content.Context
import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging
import org.json.JSONArray
import org.json.JSONObject

data class InstanceFcmConfig(
    val id: String,
    val appId: String,
    val apiKey: String,
    val senderId: String,
    val projectId: String,
)

/**
 * Firebase for several KRAB backends at once.
 *
 * Waking a dozing device needs a high-priority message, and only a sender
 * the device is registered with can send one. A device signed into several
 * KRAB servers is therefore registered with several senders, which means
 * one FirebaseApp per server.
 *
 * This lives natively because `firebase_messaging` says outright that it
 * "does not yet support multiple Firebase Apps. Default app only." — its
 * `instanceFor` is private and its token calls go to the default app. Delivery
 * still lands in the plugin's single `FirebaseMessagingService`, whatever
 * sender it came from, so only registration needs doing here; routing happens
 * in Dart on the instance the payload names.
 */
object InstanceFirebase {
    private const val TAG = "KrabInstanceFirebase"

    /** Must match InstanceRegistry.prefsKey on the Dart side. */
    private const val INSTANCES_KEY = "flutter.krab_instances"

    /**
     * Every connected instance that has published an FCM config, in the order
     * the registry holds them.
     */
    fun configs(context: Context): List<InstanceFcmConfig> {
        val prefs = context.getSharedPreferences(
            "FlutterSharedPreferences",
            Context.MODE_PRIVATE,
        )
        val raw = prefs.getString(INSTANCES_KEY, null)
        if (raw.isNullOrEmpty()) return emptyList()

        return try {
            val instances = JSONArray(raw)
            (0 until instances.length()).mapNotNull { i ->
                configOf(instances.optJSONObject(i))
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not read the instance list", e)
            emptyList()
        }
    }

    private fun configOf(entry: JSONObject?): InstanceFcmConfig? {
        val id = entry?.optString("id").orEmpty()
        val config = entry?.optJSONObject("config") ?: return null
        if (id.isEmpty()) return null

        val appId = config.optString("fcm_app_id")
        val apiKey = config.optString("fcm_api_key")
        val senderId = config.optString("fcm_sender_id")
        val projectId = config.optString("fcm_project_id")

        // An instance whose config hasn't been fetched yet.
        if (appId.isEmpty() || apiKey.isEmpty() ||
            senderId.isEmpty() || projectId.isEmpty()
        ) {
            return null
        }
        return InstanceFcmConfig(id, appId, apiKey, senderId, projectId)
    }

    /**
     * Bring up a FirebaseApp for every instance, so each server's sender can
     * reach this device.
     *
     * The first one becomes the default app, because the messaging plugin only
     * talks to that one and something has to answer it. Failing on one instance
     * must not cost the others theirs.
     */
    fun initializeAll(context: Context, configs: List<InstanceFcmConfig>) {
        for ((index, config) in configs.withIndex()) {
            try {
                appFor(context, config, isDefault = index == 0)
            } catch (e: Exception) {
                Log.w(TAG, "Firebase init failed for ${config.id}", e)
            }
        }
    }

    /**
     * The FirebaseApp for one instance, created if this is the first ask.
     *
     * The first instance gets the default app, since that is the only one the
     * messaging plugin will talk to. Both paths have to tolerate the app
     * already existing: this runs at launch and again whenever a token is
     * wanted.
     */
    private fun appFor(
        context: Context,
        config: InstanceFcmConfig,
        isDefault: Boolean,
    ): FirebaseApp {
        val name = if (isDefault) FirebaseApp.DEFAULT_APP_NAME else config.id
        return try {
            FirebaseApp.getInstance(name)
        } catch (_: IllegalStateException) {
            FirebaseApp.initializeApp(context, options(config), name)
        }
    }

    /**
     * This device's registration token for each instance, keyed by instance id.
     *
     * Every server gets the token minted for its own sender; handing one
     * server another's token would make its messages undeliverable.
     */
    fun tokens(context: Context, configs: List<InstanceFcmConfig>): Map<String, String> {
        val tokens = mutableMapOf<String, String>()
        for ((index, config) in configs.withIndex()) {
            try {
                val app = appFor(context, config, isDefault = index == 0)
                // FirebaseMessaging.getInstance(app) is package-private; the
                // component registry is the supported way to reach a secondary
                // app's messaging.
                val messaging = app.get(FirebaseMessaging::class.java)
                // Blocking is fine: this is called off the main thread, and a
                // token that isn't ready is a token the caller must wait for.
                val token = com.google.android.gms.tasks.Tasks.await(messaging.token)
                if (!token.isNullOrEmpty()) tokens[config.id] = token
            } catch (e: Exception) {
                // One server without a token still leaves the others working.
                Log.w(TAG, "No FCM token for ${config.id}", e)
            }
        }
        return tokens
    }

    private fun options(config: InstanceFcmConfig): FirebaseOptions =
        FirebaseOptions.Builder()
            .setApplicationId(config.appId)
            .setApiKey(config.apiKey)
            .setGcmSenderId(config.senderId)
            .setProjectId(config.projectId)
            .build()
}
