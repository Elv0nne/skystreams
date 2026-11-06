// Adapted from CloudStream (https://github.com/recloudstream/cloudstream), GPL-3.0.
package com.lagradost.cloudstream3.ui.result

import com.lagradost.cloudstream3.APIHolder.getApiFromNameNull
import com.lagradost.cloudstream3.LoadResponse

enum class VideoWatchState {
    /** Default value when no key is set */
    None,
    Watched,
}

/** The id the app keeps a title's state under. */
fun LoadResponse.getId(): Int =
    uniqueUrl.replace(getApiFromNameNull(apiName)?.mainUrl ?: "", "").replace("/", "").hashCode()
