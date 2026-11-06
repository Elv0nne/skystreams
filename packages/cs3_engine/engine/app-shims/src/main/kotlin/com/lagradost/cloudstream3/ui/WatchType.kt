// Adapted from CloudStream (https://github.com/recloudstream/cloudstream), GPL-3.0.
package com.lagradost.cloudstream3.ui

/** Where a title stands in the app's own library. */
enum class WatchType(val internalId: Int) {
    WATCHING(0),
    COMPLETED(1),
    ONHOLD(2),
    DROPPED(3),
    PLANTOWATCH(4),
    NONE(5);

    /** The app's label and icon for it; SkyStream has none of CloudStream's resources. */
    val stringRes: Int get() = 0
    val iconRes: Int get() = 0

    companion object {
        fun fromInternalId(id: Int?) = entries.find { value -> value.internalId == id } ?: NONE
    }
}

/** Where a title stands on a sync service's lists. */
enum class SyncWatchType(val internalId: Int) {
    NONE(-1),
    WATCHING(0),
    COMPLETED(1),
    ONHOLD(2),
    DROPPED(3),
    PLANTOWATCH(4),
    REWATCHING(5);

    /** The app's label and icon for it; SkyStream has none of CloudStream's resources. */
    val stringRes: Int get() = 0
    val iconRes: Int get() = 0

    companion object {
        fun fromInternalId(id: Int?) = entries.find { value -> value.internalId == id } ?: NONE
    }
}
