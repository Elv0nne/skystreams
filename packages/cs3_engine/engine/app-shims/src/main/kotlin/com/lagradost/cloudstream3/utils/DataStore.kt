// Adapted from CloudStream (https://github.com/recloudstream/cloudstream), GPL-3.0.
package com.lagradost.cloudstream3.utils

import android.content.Context
import android.content.SharedPreferences
import com.lagradost.cloudstream3.utils.AppUtils.parseJson
import com.lagradost.cloudstream3.utils.AppUtils.toJson

const val PREFERENCES_NAME = "rebuild_preference"

/**
 * The app's key/value store. Plugins compiled against the app inline the reified getters,
 * so the non-inline members below are what their bytecode actually calls.
 */
object DataStore {
    val mapper = com.lagradost.cloudstream3.mapper

    fun Context.getSharedPrefs(): SharedPreferences = getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    /** Android's default preferences file, without depending on androidx.preference. */
    fun Context.getDefaultSharedPrefs(): SharedPreferences =
        getSharedPreferences("${packageName}_preferences", Context.MODE_PRIVATE)

    fun getFolderName(folder: String, path: String): String = "$folder/$path"

    fun Context.getKeys(folder: String): List<String> {
        val fixedFolder = folder.trimEnd('/') + "/"
        return getSharedPrefs().all.keys.filter { it.startsWith(fixedFolder) }
    }

    fun Context.removeKey(folder: String, path: String) = removeKey(getFolderName(folder, path))

    fun Context.containsKey(folder: String, path: String): Boolean = containsKey(getFolderName(folder, path))

    fun Context.containsKey(path: String): Boolean = getSharedPrefs().contains(path)

    fun Context.removeKey(path: String) {
        val prefs = getSharedPrefs()
        if (prefs.contains(path)) prefs.edit().remove(path).apply()
    }

    fun Context.removeKeys(folder: String): Int {
        val keys = getKeys("$folder/")
        val editor = getSharedPrefs().edit()
        keys.forEach { editor.remove(it) }
        editor.apply()
        return keys.size
    }

    fun <T> Context.setKey(path: String, value: T) {
        getSharedPrefs().edit().putString(path, value?.toJson()).apply()
    }

    fun <T : Any> Context.getKey(path: String, valueType: Class<T>): T? = try {
        getSharedPrefs().getString(path, null)?.let { parseJson(it, valueType.kotlin) }
    } catch (_: Exception) {
        null
    }

    fun <T> Context.setKey(folder: String, path: String, value: T) = setKey(getFolderName(folder, path), value)

    inline fun <reified T : Any> Context.getKey(path: String, defVal: T?): T? = try {
        val json = getSharedPrefs().getString(path, null)
        if (json == null) defVal else parseJson<T>(json)
    } catch (_: Exception) {
        null
    }

    inline fun <reified T : Any> Context.getKey(path: String): T? = getKey(path, null)

    inline fun <reified T : Any> Context.getKey(folder: String, path: String): T? =
        getKey(getFolderName(folder, path), null)

    inline fun <reified T : Any> Context.getKey(folder: String, path: String, defVal: T?): T? =
        getKey(getFolderName(folder, path), defVal) ?: defVal
}
