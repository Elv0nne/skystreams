// Adapted from CloudStream (https://github.com/recloudstream/cloudstream), GPL-3.0.
package com.lagradost.cloudstream3.syncproviders

/** General-purpose repo */
class PlainAuthRepo(api: AuthAPI) : AuthRepo(api)

/**
 * A service with the app's accounts on it. SkyStream signs nobody in to CloudStream's services,
 * so plugins see what CloudStream shows a person who never signed in.
 */
abstract class AuthRepo(open val api: AuthAPI) {
    val idPrefix get() = api.idPrefix
    val name get() = api.name
    val icon get() = api.icon
    val requiresLogin get() = api.requiresLogin
    val createAccountUrl get() = api.createAccountUrl
    val isAvailable get() = !api.requiresLogin || authUser() != null

    fun authData(): AuthData? = null

    fun authToken(): AuthToken? = authData()?.token

    fun authUser(): AuthUser? = authData()?.user
}
