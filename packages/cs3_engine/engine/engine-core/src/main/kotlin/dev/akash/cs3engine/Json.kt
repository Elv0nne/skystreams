package dev.akash.cs3engine

import com.fasterxml.jackson.databind.DeserializationFeature
import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.UndeclaredThrowableException

internal object Json {
    val mapper: ObjectMapper = jacksonObjectMapper()
        .configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false)

    fun result(id: JsonNode?, value: Any?): String = mapper.writeValueAsString(mapOf("id" to id, "result" to value))

    fun error(id: JsonNode?, t: Throwable): String {
        val cause = rootCause(t)
        val error = mapOf(
            "type" to cause.javaClass.name,
            "message" to (cause.message ?: cause.toString()),
            "trace" to cause.stackTrace.take(12).joinToString("\n") { "at $it" },
        )
        return mapper.writeValueAsString(mapOf("id" to id, "error" to error))
    }

    /** Strips the wrappers reflection and class initialisation put around plugin failures. */
    fun rootCause(t: Throwable): Throwable {
        var current = t
        while (true) {
            current = when (current) {
                is InvocationTargetException -> current.targetException ?: return current
                is ExceptionInInitializerError -> current.cause ?: return current
                is UndeclaredThrowableException -> current.undeclaredThrowable ?: return current
                else -> return current
            }
        }
    }
}

internal fun JsonNode.text(name: String): String =
    get(name)?.takeIf { it.isTextual }?.asText() ?: throw IllegalArgumentException("missing string param '$name'")

internal fun JsonNode.optText(name: String): String? = get(name)?.takeIf { it.isTextual }?.asText()

internal fun JsonNode.int(name: String, default: Int): Int = get(name)?.takeIf { it.canConvertToInt() }?.asInt() ?: default

internal fun JsonNode.long(name: String, default: Long): Long = get(name)?.takeIf { it.isNumber }?.asLong() ?: default

/** A param as plain Kotlin (a boolean, number, string, list or map); null when it's absent or null. */
internal fun JsonNode.value(name: String): Any? =
    get(name)?.takeUnless { it.isNull }?.let { Json.mapper.treeToValue(it, Any::class.java) }
