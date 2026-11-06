package com.lingjhf.vlc_player

import android.app.Activity
import android.content.res.Resources
import android.provider.Settings
import android.view.WindowManager

/**
 * The app's screen brightness on Android: its window's `screenBrightness`, as
 * VLC's and mpv's players set it.
 *
 * It needs no permission and writes no system setting: the system's level is
 * back wherever the app's window isn't in front, and on [reset].
 */
internal class VlcScreenBrightness {
    /** The activity whose window is lit, or none while there isn't one. */
    var activity: Activity? = null

    /**
     * The level the screen shows now: the window's own, else the system's from
     * its setting. Under auto-brightness the setting follows the level the
     * system last chose, near enough to start a swipe from, as mpv reads it.
     */
    fun level(): Double? {
        val window = activity?.window ?: return null
        val own = window.attributes.screenBrightness
        if (own >= 0f) return own.toDouble()
        val value = runCatching {
            Settings.System.getInt(window.context.contentResolver, Settings.System.SCREEN_BRIGHTNESS)
        }.getOrNull() ?: return null
        return VlcDeviceLevels.systemBrightness(value, settingMaximum())
    }

    /** Sets the window's level, at once. */
    fun set(level: Double) {
        val window = activity?.window ?: return
        val attributes = window.attributes
        attributes.screenBrightness = VlcDeviceLevels.windowBrightness(level)
        window.attributes = attributes
    }

    /** Gives the screen back to the system's level. */
    fun reset() {
        val window = activity?.window ?: return
        val attributes = window.attributes
        attributes.screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
        window.attributes = attributes
    }

    /** The setting's maximum: 255 on most devices, more on some. */
    private fun settingMaximum(): Int {
        val resources = Resources.getSystem()
        @Suppress("DiscouragedApi") // The framework's own config, not in the SDK.
        val id = resources.getIdentifier("config_screenBrightnessSettingMaximum", "integer", "android")
        if (id == 0) return VlcDeviceLevels.DEFAULT_BRIGHTNESS_SETTING_MAX
        return runCatching { resources.getInteger(id) }
            .getOrDefault(VlcDeviceLevels.DEFAULT_BRIGHTNESS_SETTING_MAX)
    }
}
