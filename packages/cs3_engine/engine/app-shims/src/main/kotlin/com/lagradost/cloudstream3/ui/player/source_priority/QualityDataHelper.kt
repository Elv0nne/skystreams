// Adapted from CloudStream (https://github.com/recloudstream/cloudstream), GPL-3.0.
package com.lagradost.cloudstream3.ui.player.source_priority

import com.lagradost.cloudstream3.CloudStreamApp.Companion.getKey
import com.lagradost.cloudstream3.CloudStreamApp.Companion.removeKey
import com.lagradost.cloudstream3.CloudStreamApp.Companion.setKey
import com.lagradost.cloudstream3.utils.DataStoreHelper.currentAccount
import com.lagradost.cloudstream3.utils.Qualities
import com.lagradost.cloudstream3.utils.UiText
import com.lagradost.cloudstream3.utils.txt

/**
 * The priorities CloudStream's player sorts links by, per profile. SkyStream's player does not
 * read them; a plugin that sets them reads back what it set.
 */
object QualityDataHelper {
    private const val VIDEO_SOURCE_PRIORITY = "video_source_priority"
    private const val VIDEO_QUALITY_PRIORITY = "video_quality_priority"
    private const val DEFAULT_SOURCE_PRIORITY = 1

    /** Upstream's profile count. */
    private const val PROFILE_COUNT = 7

    /** Upstream also ties profiles to a network (Wi-Fi, mobile data); nothing here does. */
    data class QualityProfile(
        val name: UiText,
        val id: Int,
    )

    fun getProfiles(): List<QualityProfile> = (1..PROFILE_COUNT).map { QualityProfile(txt("Profile $it"), it) }

    fun getSourcePriority(profile: Int, name: String?): Int {
        if (name == null) return DEFAULT_SOURCE_PRIORITY
        return getKey("$currentAccount/$VIDEO_SOURCE_PRIORITY/$profile", name, DEFAULT_SOURCE_PRIORITY)
            ?: DEFAULT_SOURCE_PRIORITY
    }

    fun setSourcePriority(profile: Int, name: String, priority: Int) {
        val folder = "$currentAccount/$VIDEO_SOURCE_PRIORITY/$profile"
        // Prevent unnecessary keys
        if (priority == DEFAULT_SOURCE_PRIORITY) {
            removeKey(folder, name)
        } else {
            setKey(folder, name, priority)
        }
    }

    fun getQualityPriority(profile: Int, quality: Qualities): Int =
        getKey("$currentAccount/$VIDEO_QUALITY_PRIORITY/$profile", quality.value.toString(), quality.defaultPriority)
            ?: quality.defaultPriority
}
