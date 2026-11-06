package com.lagradost.cloudstream3.utils

import android.widget.ImageView

/**
 * CloudStream's image loader (Coil there). SkyStream draws extension screens itself and shows no
 * extension images in them, so loading does nothing. StreamCenter's settings preload icons with it.
 */
object ImageLoader {
    @Suppress("UNUSED_PARAMETER")
    fun ImageView.loadImage(imageData: String?, headers: Map<String, String>? = null, builder: (Any) -> Unit = {}) {}
}
