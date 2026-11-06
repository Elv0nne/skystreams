// Adapted from CloudStream (https://github.com/recloudstream/cloudstream), GPL-3.0.
package com.lagradost.cloudstream3

import android.content.Context
import com.lagradost.cloudstream3.utils.DataStore.getKey
import com.lagradost.cloudstream3.utils.DataStore.getKeys
import com.lagradost.cloudstream3.utils.DataStore.removeKey
import com.lagradost.cloudstream3.utils.DataStore.removeKeys
import com.lagradost.cloudstream3.utils.DataStore.setKey

/** Plugins only use the companion: the app context and the key/value store on top of it. */
open class CloudStreamApp {
    companion object {
        @Volatile
        private var appContext: Context? = null

        var context: Context?
            get() = appContext
            private set(value) {
                appContext = value
                com.lagradost.api.setContext(value)
            }

        /** Set by the engine host; upstream does this in `Application.onCreate`. */
        fun installContext(value: Context?) {
            context = value
        }

        fun <T : Any> getKeyClass(path: String, valueType: Class<T>): T? = context?.getKey(path, valueType)

        fun <T : Any> setKeyClass(path: String, value: T) {
            context?.setKey(path, value)
        }

        fun removeKeys(folder: String): Int? = context?.removeKeys(folder)

        fun <T> setKey(path: String, value: T) {
            context?.setKey(path, value)
        }

        fun <T> setKey(folder: String, path: String, value: T) {
            context?.setKey(folder, path, value)
        }

        inline fun <reified T : Any> getKey(path: String, defVal: T?): T? = context?.getKey(path, defVal)

        inline fun <reified T : Any> getKey(path: String): T? = context?.getKey(path)

        inline fun <reified T : Any> getKey(folder: String, path: String): T? = context?.getKey(folder, path)

        inline fun <reified T : Any> getKey(folder: String, path: String, defVal: T?): T? =
            context?.getKey(folder, path, defVal)

        fun getKeys(folder: String): List<String>? = context?.getKeys(folder)

        fun removeKey(folder: String, path: String) {
            context?.removeKey(folder, path)
        }

        fun removeKey(path: String) {
            context?.removeKey(path)
        }
    }
}

/** Older plugins reach the context and key store through the app's previous Application class. */
open class AcraApplication {
    companion object {
        val context: Context? get() = CloudStreamApp.context

        fun removeKeys(folder: String): Int? = CloudStreamApp.removeKeys(folder)

        fun <T> setKey(path: String, value: T) = CloudStreamApp.setKey(path, value)

        fun <T> setKey(folder: String, path: String, value: T) = CloudStreamApp.setKey(folder, path, value)

        inline fun <reified T : Any> getKey(path: String, defVal: T?): T? = context?.getKey(path, defVal)

        inline fun <reified T : Any> getKey(path: String): T? = context?.getKey(path)

        inline fun <reified T : Any> getKey(folder: String, path: String): T? = context?.getKey(folder, path)

        inline fun <reified T : Any> getKey(folder: String, path: String, defVal: T?): T? =
            context?.getKey(folder, path, defVal)

        fun getKeys(folder: String): List<String>? = CloudStreamApp.getKeys(folder)

        fun removeKey(folder: String, path: String) = CloudStreamApp.removeKey(folder, path)

        fun removeKey(path: String) = CloudStreamApp.removeKey(path)
    }
}
