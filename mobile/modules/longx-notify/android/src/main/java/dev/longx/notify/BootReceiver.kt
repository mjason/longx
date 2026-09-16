package dev.longx.notify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** the notify connection comes back after a reboot, when a server is remembered */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) NotifyService.sync(context)
    }
}
