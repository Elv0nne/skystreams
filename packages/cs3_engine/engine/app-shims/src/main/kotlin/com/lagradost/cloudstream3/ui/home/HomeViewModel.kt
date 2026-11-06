package com.lagradost.cloudstream3.ui.home

/**
 * The part of CloudStream's home screen model extensions call: a Vietnamese sync plugin reads the
 * resume list. SkyStream keeps no CloudStream resume list, so it's empty.
 */
class HomeViewModel {
    companion object {
        suspend fun getResumeWatching(): List<Any>? = emptyList()
    }
}
