package com.lagradost.cloudstream3

import android.content.Context
import kotlin.io.path.createTempDirectory

/** Gives the shims a key/value store in a temporary folder, as the engine does when it starts. */
object TestStore {
    private val ready by lazy {
        System.setProperty("cs3.dataDir", createTempDirectory("cs3-shims").toString())
        CloudStreamApp.installContext(Context())
    }

    fun install() = ready
}
