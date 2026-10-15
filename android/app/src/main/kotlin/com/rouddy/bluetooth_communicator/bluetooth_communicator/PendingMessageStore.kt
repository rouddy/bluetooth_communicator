package com.rouddy.bluetooth_communicator.bluetooth_communicator

import java.util.Base64

data class PendingMessage(val deviceId: String, val message: String, val receivedAt: Long)

/**
 * Messages that arrived while no Flutter listener was attached (e.g. the activity was
 * closed but the service kept running). They're persisted so they also survive the
 * process being killed before the UI comes back, and handed to Dart on the next listen.
 *
 * Storage is injected so the class stays plain JVM code (unit tested); the app backs it
 * with SharedPreferences. Fields are Base64-encoded, one message per line.
 */
class PendingMessageStore(
    private val load: () -> String?,
    private val save: (String) -> Unit,
    private val capacity: Int = 500
) {
    @Synchronized
    fun add(message: PendingMessage) {
        save(encode((decode(load()) + message).takeLast(capacity)))
    }

    /** Returns the stored messages, oldest first, and clears the store. */
    @Synchronized
    fun drain(): List<PendingMessage> {
        val messages = decode(load())
        if (messages.isNotEmpty()) {
            save("")
        }
        return messages
    }

    private companion object {
        val encoder: Base64.Encoder = Base64.getEncoder()
        val decoder: Base64.Decoder = Base64.getDecoder()

        fun encode(messages: List<PendingMessage>) = messages.joinToString("\n") {
            listOf(it.deviceId, it.message, it.receivedAt.toString())
                .joinToString(":") { field -> encoder.encodeToString(field.toByteArray()) }
        }

        fun decode(raw: String?): List<PendingMessage> {
            if (raw.isNullOrEmpty()) {
                return emptyList()
            }
            return raw.lines().mapNotNull { line ->
                val fields = line.split(":").map { String(decoder.decode(it)) }
                if (fields.size != 3) {
                    return@mapNotNull null
                }
                PendingMessage(fields[0], fields[1], fields[2].toLongOrNull() ?: 0L)
            }
        }
    }
}
