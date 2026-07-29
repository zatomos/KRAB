package fr.zatomos.krab

import android.app.Application

/**
 * Initialises Firebase from the per-instance config the app cached at runtime,
 * before FirebaseMessagingService can run.
 */
class KrabApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        InstanceFirebase.initializeAll(this, InstanceFirebase.configs(this))
    }
}
