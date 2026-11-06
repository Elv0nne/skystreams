// Adapted from CloudStream (https://github.com/recloudstream/cloudstream), GPL-3.0.
package com.lagradost.cloudstream3.extractors

import com.lagradost.cloudstream3.SubtitleFile
import com.lagradost.cloudstream3.utils.ExtractorApi
import com.lagradost.cloudstream3.utils.ExtractorLink
import dev.akash.cs3engine.host.HostHooks

/**
 * CloudStream's library dropped this extractor in November 2025, its sites gone and the keys it
 * decoded with no longer published. Plugins built before then still register it, or extend it for
 * a site of their own, so it stays as an extractor that finds no links.
 */
open class Chillx : ExtractorApi() {
    override val name = "Chillx"
    override val mainUrl = "https://chillx.top"
    override val requiresReferer = true

    override suspend fun getUrl(
        url: String,
        referer: String?,
        subtitleCallback: (SubtitleFile) -> Unit,
        callback: (ExtractorLink) -> Unit,
    ) {
        HostHooks.log("$name: CloudStream no longer has the Chillx extractor, so $url gives no links")
    }
}
