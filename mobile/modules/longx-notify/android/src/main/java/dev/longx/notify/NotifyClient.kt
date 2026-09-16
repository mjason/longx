package dev.longx.notify

import android.os.Handler
import android.os.Looper
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/** one WebSocket on Longx's `notify` channel: heartbeats, reconnects with a growing pause, events to the listener (main thread) */
class NotifyClient(private val socketUrl: String, private val listener: Listener) {
    interface Listener {
        fun onState(connected: Boolean)
        fun onRunning(running: List<JSONObject>)
        fun onEvent(event: JSONObject)
    }

    private val main = Handler(Looper.getMainLooper())
    private val http = OkHttpClient.Builder().pingInterval(25, TimeUnit.SECONDS).readTimeout(0, TimeUnit.MILLISECONDS).build()
    private var socket: WebSocket? = null
    private var refs = 0
    private var attempts = 0
    private var closed = false
    private val heartbeat = object : Runnable {
        override fun run() {
            socket?.send(PhoenixMessage.heartbeat(nextRef()).encode())
            main.postDelayed(this, HEARTBEAT_MS)
        }
    }

    fun start() {
        closed = false
        connect()
    }

    fun stop() {
        closed = true
        main.removeCallbacksAndMessages(null)
        socket?.close(1000, "bye")
        socket = null
    }

    private fun nextRef(): String = (++refs).toString()

    private fun connect() {
        if (closed) return
        socket = http.newWebSocket(Request.Builder().url(socketUrl).build(), object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                attempts = 0
                webSocket.send(PhoenixMessage.join(JOIN_REF, nextRef(), TOPIC).encode())
                main.post { listener.onState(true) }
                main.postDelayed(heartbeat, HEARTBEAT_MS)
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                val message = PhoenixMessage.decode(text) ?: return
                when {
                    message.topic == TOPIC && message.event == "event" -> main.post { listener.onEvent(message.payload) }
                    message.topic == TOPIC && message.event == "phx_reply" && message.joinRef == JOIN_REF -> {
                        val running = message.payload.optJSONObject("response")?.optJSONArray("running") ?: return
                        val list = (0 until running.length()).mapNotNull { running.optJSONObject(it) }
                        main.post { listener.onRunning(list) }
                    }
                }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) = lost()
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = lost()
        })
    }

    private fun lost() {
        main.removeCallbacks(heartbeat)
        socket = null
        main.post { listener.onState(false) }
        if (closed) return
        val pause = RETRY_MS[minOf(attempts, RETRY_MS.size - 1)]
        attempts++
        main.postDelayed({ connect() }, pause)
    }

    companion object {
        const val TOPIC = "notify"
        private const val JOIN_REF = "1"
        private const val HEARTBEAT_MS = 30_000L
        private val RETRY_MS = longArrayOf(1_000, 2_000, 5_000, 10_000, 30_000)
    }
}
