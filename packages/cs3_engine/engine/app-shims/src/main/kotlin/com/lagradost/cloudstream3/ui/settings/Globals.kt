// Adapted from CloudStream (https://github.com/recloudstream/cloudstream), GPL-3.0.
package com.lagradost.cloudstream3.ui.settings

/** Plugins ask which layout the app uses (phone, TV...) to adapt their UI; the engine's host is a phone. */
object Globals {
    var beneneCount = 0

    const val PHONE: Int = 0b00001
    const val TV: Int = 0b00010
    const val EMULATOR: Int = 0b00100

    @Volatile
    var layoutId = PHONE

    fun isLandscape(): Boolean = isLayout(TV or EMULATOR)

    /** True if the layout is any of [flags], e.g. `isLayout(TV or EMULATOR)`. */
    fun isLayout(flags: Int): Boolean = (layoutId and flags) != 0
}
