package dev.longx.notify

import org.json.JSONArray
import org.json.JSONObject

/** one message of Phoenix's channel protocol v2: `[join_ref, ref, topic, event, payload]` */
data class PhoenixMessage(val joinRef: String?, val ref: String?, val topic: String, val event: String, val payload: JSONObject) {
    fun encode(): String =
        JSONArray().put(joinRef ?: JSONObject.NULL).put(ref ?: JSONObject.NULL).put(topic).put(event).put(payload).toString()

    companion object {
        fun join(joinRef: String, ref: String, topic: String) = PhoenixMessage(joinRef, ref, topic, "phx_join", JSONObject())
        fun heartbeat(ref: String) = PhoenixMessage(null, ref, "phoenix", "heartbeat", JSONObject())

        fun decode(text: String): PhoenixMessage? {
            val array = runCatching { JSONArray(text) }.getOrNull() ?: return null
            if (array.length() != 5) return null
            val payload = array.optJSONObject(4) ?: return null
            return PhoenixMessage(
                joinRef = array.optString(0).takeUnless { array.isNull(0) },
                ref = array.optString(1).takeUnless { array.isNull(1) },
                topic = array.optString(2),
                event = array.optString(3),
                payload = payload,
            )
        }
    }
}
