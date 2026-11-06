package com.lingjhf.vlc_player

/// Holds players' starts while something they would race is under way: see
/// VlcFontWarmup. Open, a start runs at once; closed, it waits, and every
/// waiting start runs, in order and once, when the gate opens again.
internal class VlcStartGate {
    private var open = true
    private val waiting = ArrayList<() -> Unit>()

    @Synchronized
    fun close() {
        open = false
    }

    fun whenOpen(start: () -> Unit) {
        val now = synchronized(this) {
            if (!open) waiting.add(start)
            open
        }
        if (now) start()
    }

    fun open() {
        val starts = synchronized(this) {
            open = true
            ArrayList(waiting).also { waiting.clear() }
        }
        starts.forEach { it() }
    }
}
