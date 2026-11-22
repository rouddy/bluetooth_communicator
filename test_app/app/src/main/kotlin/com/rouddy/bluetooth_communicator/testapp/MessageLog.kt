package com.rouddy.bluetooth_communicator.testapp

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The conversation, kept in prefs so messages that arrive through [ReceiveService]
 * while the activity is closed show up when it opens.
 */
object MessageLog {
    private const val PREFS = "message_log"
    private const val KEY_ENTRIES = "entries"
    private const val KEY_NAMES = "peer_names"
    private const val MAX_ENTRIES = 200
    private const val MAX_SEEN = 500

    private val listeners = CopyOnWriteArrayList<() -> Unit>()

    // (peerId, msgId) of recent messages: the communicator may deliver one twice
    // (at-least-once, docs/protocol.md 9절).
    private val seen = LinkedHashSet<String>()

    fun addListener(listener: () -> Unit) = listeners.add(listener)

    fun removeListener(listener: () -> Unit) = listeners.remove(listener)

    @Synchronized
    fun lines(context: Context): List<String> {
        val entries = load(context)
        return List(entries.length()) { entries.getJSONObject(it).getString("line") }
    }

    /** Records a received message; returns false for a duplicate. */
    @Synchronized
    fun received(context: Context, peerId: String, text: String, msgId: Long, via: String): Boolean {
        if (!seen.add("$peerId:$msgId")) {
            return false
        }
        while (seen.size > MAX_SEEN) {
            seen.remove(seen.first())
        }
        append(context, "id-in-$peerId-$msgId", "${time()} ← ${nameOf(context, peerId)}: $text  ($via, #$msgId)")
        return true
    }

    @Synchronized
    fun sent(context: Context, localId: String, peerName: String, text: String) {
        append(context, localId, "${time()} → $peerName: $text  · 전송 중")
    }

    @Synchronized
    fun result(context: Context, localId: String, status: String) {
        val entries = load(context)
        for (i in 0 until entries.length()) {
            val entry = entries.getJSONObject(i)
            if (entry.getString("id") == localId) {
                entry.put("line", entry.getString("line").substringBeforeLast(" · ") + " · " + status)
            }
        }
        save(context, entries)
    }

    @Synchronized
    fun clear(context: Context) = save(context, JSONArray())

    /** Remembers peer names, so messages received without the activity are labeled. */
    fun rememberName(context: Context, peerId: String, name: String) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val names = JSONObject(prefs.getString(KEY_NAMES, "{}") ?: "{}")
        names.put(peerId, name)
        prefs.edit().putString(KEY_NAMES, names.toString()).apply()
    }

    private fun nameOf(context: Context, peerId: String): String {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return JSONObject(prefs.getString(KEY_NAMES, "{}") ?: "{}").optString(peerId).ifEmpty { peerId.take(8) }
    }

    private fun append(context: Context, id: String, line: String) {
        val entries = load(context)
        entries.put(JSONObject().put("id", id).put("line", line))
        while (entries.length() > MAX_ENTRIES) {
            entries.remove(0)
        }
        save(context, entries)
    }

    private fun load(context: Context): JSONArray {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_ENTRIES, null)
        return runCatching { JSONArray(raw) }.getOrElse { JSONArray() }
    }

    private fun save(context: Context, entries: JSONArray) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_ENTRIES, entries.toString())
            .apply()
        listeners.forEach { it() }
    }

    private fun time(): String = SimpleDateFormat("HH:mm:ss", Locale.US).format(Date())
}
