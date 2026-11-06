// Adapted from CloudStream (https://github.com/recloudstream/cloudstream), GPL-3.0.
package com.lagradost.cloudstream3.syncproviders

/**
 * Before CloudStream's 2025 account rework: a service signed in to from a dialog in the app.
 * FStream still keeps its settings in one.
 */
interface InAppAuthAPI {
    data class LoginData(
        val username: String? = null,
        val password: String? = null,
        val server: String? = null,
        val email: String? = null,
    )

    // this is for displaying the UI
    val requiresPassword: Boolean
    val requiresUsername: Boolean
    val requiresServer: Boolean
    val requiresEmail: Boolean

    // if this is false we can assume that getLatestLoginData returns null and wont be called
    val storesPasswordInPlainText: Boolean

    // return true if logged in successfully
    suspend fun login(data: LoginData): Boolean

    // used to fill the UI if you want to edit any data about your login info
    fun getLatestLoginData(): LoginData?
}

abstract class InAppAuthAPIManager(defIndex: Int) : AccountManager(defIndex), InAppAuthAPI {
    override val requiresPassword = false
    override val requiresUsername = false
    override val requiresEmail = false
    override val requiresServer = false
    override val storesPasswordInPlainText = true
    open val requiresLogin = true
    open val createAccountUrl: String? = null
    open val icon: Int? = null

    open val name: String
        get() = throw NotImplementedError()

    override val idPrefix: String
        get() = throw NotImplementedError()

    // runs on startup
    open suspend fun initialize() {
    }

    open fun logOut() {
        throw NotImplementedError()
    }

    override suspend fun login(data: InAppAuthAPI.LoginData): Boolean = throw NotImplementedError()

    override fun getLatestLoginData(): InAppAuthAPI.LoginData? = throw NotImplementedError()

    override fun loginInfo(): AuthAPI.LoginInfo? = throw NotImplementedError()
}
