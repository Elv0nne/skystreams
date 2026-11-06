package com.lingjhf.vlc_player

import kotlin.math.roundToInt

/**
 * The arithmetic behind the player's volume and brightness swipes, apart from
 * the Android calls so the JVM can test it.
 */
internal object VlcDeviceLevels {
    /** VLC's floor: a window brightness of 0 turns some panels' backlight off. */
    const val MIN_WINDOW_BRIGHTNESS = 0.01f

    /** The brightness setting's maximum where the platform names none. */
    const val DEFAULT_BRIGHTNESS_SETTING_MAX = 255

    /** The media stream's step for [level], 0..1, on a stream of [max] steps. */
    fun indexFor(level: Double, max: Int): Int {
        if (max <= 0 || level.isNaN()) return 0
        return (level.coerceIn(0.0, 1.0) * max).roundToInt().coerceIn(0, max)
    }

    /** The level, 0..1, of step [index] on a stream of [max] steps. */
    fun levelFor(index: Int, max: Int): Double =
        if (max <= 0) 0.0 else index.coerceIn(0, max).toDouble() / max

    /**
     * Whether a raise from [before] to [wanted] that left the stream at [actual]
     * was held back: Android's hearing-safety limit keeps a raise past the safe
     * level on headphones until the person confirms, and asks them only for a
     * call that shows the system's UI. A lowering is never held back.
     */
    fun heldBack(wanted: Int, before: Int, actual: Int): Boolean =
        wanted > before && actual != wanted

    /** The window brightness for [level], 0..1, never under [MIN_WINDOW_BRIGHTNESS]. */
    fun windowBrightness(level: Double): Float =
        if (level.isNaN()) {
            MIN_WINDOW_BRIGHTNESS
        } else {
            level.coerceIn(MIN_WINDOW_BRIGHTNESS.toDouble(), 1.0).toFloat()
        }

    /** The system's brightness, 0..1, from its setting [value] on a scale of [max]. */
    fun systemBrightness(value: Int, max: Int): Double {
        val scale = if (max > 0) max else DEFAULT_BRIGHTNESS_SETTING_MAX
        return (value.toDouble() / scale).coerceIn(0.0, 1.0)
    }
}
