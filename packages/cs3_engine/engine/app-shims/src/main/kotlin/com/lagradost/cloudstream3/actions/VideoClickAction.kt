// Adapted from CloudStream (https://github.com/recloudstream/cloudstream), GPL-3.0.
package com.lagradost.cloudstream3.actions

/**
 * Something the app offers to do with a video's links, like opening them in another app. SkyStream
 * shows none of these, so plugins can register them and nothing runs them.
 */
abstract class VideoClickAction {
    /** Determines which plugin a given provider is from. This is the full path to the plugin. */
    var sourcePlugin: String? = null
}
