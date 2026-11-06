package dev.akash.cs3engine

import com.fasterxml.jackson.databind.DeserializationContext
import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.databind.SerializerProvider
import com.fasterxml.jackson.databind.deser.DeserializerCache
import com.fasterxml.jackson.databind.ser.SerializerCache
import com.fasterxml.jackson.databind.util.LRUMap
import java.util.Collections
import java.util.IdentityHashMap
import java.util.concurrent.atomic.AtomicReference

/**
 * Jackson caches serializers, deserializers, types and Kotlin reflection data per class, some
 * without a size limit. An entry for one class of an unloaded plugin keeps the plugin's whole
 * class loader, and so all its classes and static data, in memory. Unloading clears them.
 *
 * Reaches into Jackson internals (the library pins 2.13); if a field is missing, that cache
 * is simply left alone.
 */
internal object JacksonCaches {
    fun clear(mapper: ObjectMapper) {
        runCatching { mapper.typeFactory.clearCache() }
        runCatching { (field(ObjectMapper::class.java, "_rootDeserializers", mapper) as MutableMap<*, *>).clear() }
        runCatching {
            (field(DeserializationContext::class.java, "_cache", mapper.deserializationContext) as DeserializerCache)
                .flushCachedDeserializers()
        }
        runCatching {
            val serializers = field(SerializerProvider::class.java, "_serializerCache", mapper.serializerProviderInstance)
                as SerializerCache
            serializers.flush()
            // flush() leaves the lock-free snapshot of the cache in place.
            (field(SerializerCache::class.java, "_readOnlyMap", serializers) as AtomicReference<*>).set(null)
        }
        runCatching { clearKotlinReflectionCaches(mapper) }
    }

    /** jackson-module-kotlin keeps a ReflectionCache per registration, held by its introspectors. */
    private fun clearKotlinReflectionCaches(mapper: ObjectMapper) {
        val caches = Collections.newSetFromMap(IdentityHashMap<Any, Boolean>())
        val introspectors = listOf(mapper.serializationConfig, mapper.deserializationConfig)
            .flatMap { it.annotationIntrospector.allIntrospectors() }
        for (introspector in introspectors) {
            for (f in introspector.javaClass.declaredFields) {
                if (f.type.name == "com.fasterxml.jackson.module.kotlin.ReflectionCache") {
                    f.isAccessible = true
                    f.get(introspector)?.let(caches::add)
                }
            }
        }
        for (cache in caches) {
            for (f in cache.javaClass.declaredFields) {
                if (LRUMap::class.java.isAssignableFrom(f.type)) {
                    f.isAccessible = true
                    (f.get(cache) as LRUMap<*, *>?)?.clear()
                }
            }
        }
    }

    private fun field(owner: Class<*>, name: String, target: Any): Any =
        owner.getDeclaredField(name).apply { isAccessible = true }.get(target)
}
