// Adapted from CloudStream (https://github.com/recloudstream/cloudstream), GPL-3.0.
package com.lagradost.cloudstream3.syncproviders.providers

import com.lagradost.cloudstream3.syncproviders.AuthData
import com.lagradost.cloudstream3.syncproviders.SyncAPI
import com.lagradost.cloudstream3.syncproviders.SyncIdName

/** Simkl, as the app's account settings offer it. Nobody is signed in to it here, so it has no lists to give. */
class SimklApi : SyncAPI() {
    override val name = "Simkl"
    override val idPrefix = "simkl"
    override val mainUrl = "https://api.simkl.com"
    override val createAccountUrl = "$mainUrl/signup"
    override val syncIdName = SyncIdName.Simkl

    override suspend fun status(auth: AuthData?, id: String): AbstractSyncStatus? = null

    override suspend fun load(auth: AuthData?, id: String): SyncResult? = null

    override suspend fun library(auth: AuthData?): LibraryMetadata? = null
}
