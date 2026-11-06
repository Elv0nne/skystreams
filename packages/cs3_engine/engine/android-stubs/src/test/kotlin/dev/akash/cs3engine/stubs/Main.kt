package dev.akash.cs3engine.stubs

import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit

/** Runs [block] on the stand-ins' main thread and returns its result, or throws what it threw. */
fun <T> onMain(block: () -> T): T {
    if (MainThread.isMainThread()) return block()
    val result = CompletableFuture<T>()
    MainThread.post {
        try {
            result.complete(block())
        } catch (t: Throwable) {
            result.completeExceptionally(t)
        }
    }
    return try {
        result.get(10, TimeUnit.SECONDS)
    } catch (e: ExecutionException) {
        throw e.cause ?: e
    }
}

/** Waits until what was posted to the main thread so far has run, and what that posted, [rounds] deep. */
fun drainMain(rounds: Int = 3) {
    repeat(rounds) { onMain { } }
}
