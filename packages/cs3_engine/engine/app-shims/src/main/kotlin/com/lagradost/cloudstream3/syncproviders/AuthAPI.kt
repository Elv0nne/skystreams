// Adapted from CloudStream (https://github.com/recloudstream/cloudstream), GPL-3.0.
package com.lagradost.cloudstream3.syncproviders

import com.fasterxml.jackson.annotation.JsonProperty

data class AuthToken(
    @JsonProperty("accessToken") val accessToken: String? = null,
    @JsonProperty("refreshToken") val refreshToken: String? = null,
    /** In UnixTime (sec) when it expires */
    @JsonProperty("accessTokenLifetime") val accessTokenLifetime: Long? = null,
    /** In UnixTime (sec) when it expires */
    @JsonProperty("refreshTokenLifetime") val refreshTokenLifetime: Long? = null,
    @JsonProperty("payload") val payload: String? = null,
)

data class AuthUser(
    @JsonProperty("name") val name: String?,
    @JsonProperty("id") val id: Int,
    @JsonProperty("profilePicture") val profilePicture: String? = null,
    @JsonProperty("profilePictureHeaders") val profilePictureHeaders: Map<String, String>? = null,
)

data class AuthData(
    @JsonProperty("user") val user: AuthUser,
    @JsonProperty("token") val token: AuthToken,
)

/** A service a person signs in to, as CloudStream has them since its 2025 account rework. */
abstract class AuthAPI {
    open val name: String = "NONE"
    open val idPrefix: String = "NONE"

    /** Drawable icon of the service */
    open val icon: Int? = null

    /** If this service requires an account to use */
    open val requiresLogin: Boolean = true

    /** Link to a website for creating a new account */
    open val createAccountUrl: String? = null

    /** What the app showed for a signed-in account before the rework; plugins of that time make these. */
    class LoginInfo(
        val profilePicture: String? = null,
        val name: String?,
        val accountIndex: Int,
    )
}
