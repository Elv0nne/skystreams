package com.lingjhf.vlc_player

/// The play a source or the viewer asked for, started once [gate] lets it -
/// unless something undid it first: a pause, a stop, a newer request, or the
/// view going. Main thread only; [gate] opens on the main thread too.
///
/// [onWaitingChanged] hears whenever a play starts or stops waiting at the
/// gate, so a snapshot can say so: the wait is up to a minute with nothing
/// wrong with the media, which a host must not take for a stall (FORK.md 33).
internal class VlcPlayRequests(
    private val gate: VlcStartGate,
    private val onWaitingChanged: () -> Unit = {},
) {
    private var current = 0

    /// Whether a play waits at the closed gate.
    var waiting = false
        private set

    /// Runs [start] when the gate is open, if no newer request or [cancel]
    /// came in between.
    fun request(start: () -> Unit) {
        val request = ++current
        var ran = false
        gate.whenOpen {
            ran = true
            if (request == current) {
                // Said before the play starts, so no snapshot the start
                // sends says it still waits.
                setWaiting(false)
                start()
            }
        }
        if (!ran) setWaiting(true)
    }

    /// Undoes a play still waiting at the gate.
    fun cancel() {
        current += 1
        setWaiting(false)
    }

    private fun setWaiting(value: Boolean) {
        if (waiting == value) return
        waiting = value
        onWaitingChanged()
    }
}
