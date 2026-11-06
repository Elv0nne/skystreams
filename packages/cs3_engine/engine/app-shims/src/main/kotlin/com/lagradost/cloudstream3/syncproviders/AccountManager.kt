// Adapted from CloudStream (https://github.com/recloudstream/cloudstream), GPL-3.0.
package com.lagradost.cloudstream3.syncproviders

import com.lagradost.cloudstream3.CloudStreamApp.Companion.getKey
import com.lagradost.cloudstream3.CloudStreamApp.Companion.removeKeys
import com.lagradost.cloudstream3.CloudStreamApp.Companion.setKey
import com.lagradost.cloudstream3.syncproviders.providers.AniListApi
import com.lagradost.cloudstream3.syncproviders.providers.SimklApi

/**
 * CloudStream's accounts. SkyStream signs nobody in to CloudStream's services (see [AuthRepo]),
 * so plugins that show a signed-in person's lists show none.
 *
 * Plugins built before CloudStream's 2025 account rework extend this through
 * [InAppAuthAPIManager] and keep their settings under an account index, as they did then.
 */
abstract class AccountManager(private val defIndex: Int) {
    companion object {
        const val NONE_ID: Int = -1
        val aniListApi = AniListApi()
        val simklApi = SimklApi()

        /** Every service, as the app's account settings list them. */
        val allApis: Array<AuthRepo>
            get() = arrayOf(SyncRepo(aniListApi), SyncRepo(simklApi))

        /** The services that keep a person's lists. */
        val syncApis: Array<SyncRepo>
            get() = arrayOf(SyncRepo(aniListApi), SyncRepo(simklApi))

        /** Before the rework: services signed in to from a dialog in the app. */
        val inAppAuths: List<InAppAuthAPIManager>
            get() = emptyList()
    }

    // The rest is the account index of the time before the rework.
    abstract val idPrefix: String

    abstract fun loginInfo(): AuthAPI.LoginInfo?

    var accountIndex = defIndex
    private var lastAccountIndex = defIndex
    protected val accountId get() = "${idPrefix}_account_$accountIndex"
    private val accountActiveKey get() = "${idPrefix}_active"

    // int array of all accounts indexes
    private val accountsKey get() = "${idPrefix}_accounts"

    protected fun removeAccountKeys() {
        removeKeys(accountId)
        val accounts = getAccounts()?.toMutableList() ?: mutableListOf()
        accounts.remove(accountIndex)
        setKey(accountsKey, accounts.toIntArray())

        init()
    }

    fun getAccounts(): IntArray? = getKey(accountsKey, intArrayOf())

    fun init() {
        accountIndex = getKey(accountActiveKey, defIndex) ?: defIndex
        val accounts = getAccounts()
        if (accounts?.isNotEmpty() == true && this.loginInfo() == null) {
            accountIndex = accounts.first()
        }
    }

    protected fun switchToNewAccount() {
        val accounts = getAccounts()
        lastAccountIndex = accountIndex
        accountIndex = (accounts?.maxOrNull() ?: 0) + 1
    }

    protected fun switchToOldAccount() {
        accountIndex = lastAccountIndex
    }

    protected fun registerAccount() {
        setKey(accountActiveKey, accountIndex)
        val accounts = getAccounts()?.toMutableList() ?: mutableListOf()
        if (!accounts.contains(accountIndex)) {
            accounts.add(accountIndex)
        }

        setKey(accountsKey, accounts.toIntArray())
    }

    fun changeAccount(index: Int) {
        accountIndex = index
        setKey(accountActiveKey, index)
    }
}
