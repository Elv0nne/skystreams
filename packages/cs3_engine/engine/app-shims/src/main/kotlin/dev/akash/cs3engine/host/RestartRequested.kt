package dev.akash.cs3engine.host

/**
 * Thrown where an extension's code asks to restart the app: the app's launch intent with
 * `Intent.makeRestartActivityTask`, then an exit, which would end SkyStream (on iOS, the whole app).
 * It ends the extension's code before the exit, and the engine reloads the extension instead. An
 * Error, not an Exception, so a `catch (e: Exception)` around the restart doesn't swallow it. 44 of
 * the 79 settings screens surveyed (2026-10-05) restart this way.
 */
class RestartRequested : Error("the extension asked to restart the app; SkyStream reloads it instead") {
    /**
     * Whoever threw it has told the engine already ([HostHooks.restartRequested]). Some extensions catch
     * every Throwable around their restart (NetNaija's and RaghavAnime's), which would hide it otherwise.
     */
    @Volatile
    var reported: Boolean = false
}
