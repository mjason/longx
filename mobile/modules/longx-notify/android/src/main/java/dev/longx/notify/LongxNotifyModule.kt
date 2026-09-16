package dev.longx.notify

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

/**
 * `LongxNotify` for JavaScript: `start(socketUrl, token)` points the
 * foreground service at the paired server (remembered, so a reboot brings
 * it back), `stop()` ends it and forgets.
 */
class LongxNotifyModule : Module() {
    override fun definition() = ModuleDefinition {
        Name("LongxNotify")

        Function("start") { socketUrl: String, token: String ->
            appContext.reactContext?.let { context ->
                Prefs(context).save(socketUrl, token)
                NotifyService.sync(context)
            }
            null
        }

        Function("stop") {
            appContext.reactContext?.let { context ->
                Prefs(context).clear()
                NotifyService.sync(context)
            }
            null
        }
    }
}
