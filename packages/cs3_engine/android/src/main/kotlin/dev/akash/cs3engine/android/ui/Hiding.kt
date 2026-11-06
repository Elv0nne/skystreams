package dev.akash.cs3engine.android.ui

import android.view.WindowManager.LayoutParams

/** How an extension's window is kept out of sight while its views stay live: SkyStream's sheet shows them. */
internal object Hiding {
    fun hide(params: LayoutParams) {
        params.alpha = 0f
        params.dimAmount = 0f
        params.flags = (params.flags or LayoutParams.FLAG_NOT_TOUCHABLE or LayoutParams.FLAG_NOT_FOCUSABLE) and
            LayoutParams.FLAG_DIM_BEHIND.inv()
        params.windowAnimations = 0
    }

    fun isHidden(params: LayoutParams): Boolean =
        params.alpha == 0f &&
            params.flags and LayoutParams.FLAG_NOT_TOUCHABLE != 0 &&
            params.flags and LayoutParams.FLAG_NOT_FOCUSABLE != 0
}
