package dev.longx.notify

import android.content.Context
import androidx.core.content.edit

/** the service's own memory of where to connect: outlives the JS side (a reboot, a killed process) */
class Prefs(context: Context) {
    private val store = context.getSharedPreferences("longx-notify", Context.MODE_PRIVATE)

    val socketUrl: String? get() = store.getString("socket", null)
    val token: String? get() = store.getString("token", null)

    fun save(socketUrl: String, token: String) = store.edit {
        putString("socket", socketUrl)
        putString("token", token)
    }

    fun clear() = store.edit { clear() }
}
