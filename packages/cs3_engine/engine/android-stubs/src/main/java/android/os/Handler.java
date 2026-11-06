package android.os;

import dev.akash.cs3engine.stubs.MainThread;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Future;

/**
 * Every Handler posts to the engine's single main thread, whatever Looper it was given, and keeps what it
 * posted until it runs, so removeCallbacks takes it back: a loop that posts itself again stops only so.
 */
public class Handler {
    private static final class Pending {
        final Runnable task;
        final Object token;
        Future<?> future;

        Pending(Runnable task, Object token) {
            this.task = task;
            this.token = token;
        }
    }

    private final List<Pending> pending = new ArrayList<>();

    public Handler() {}
    public Handler(Looper looper) {}

    public final boolean post(Runnable r) { return schedule(r, null, 0); }
    public final boolean postDelayed(Runnable r, long delayMillis) { return schedule(r, null, delayMillis); }
    public final boolean postDelayed(Runnable r, Object token, long delayMillis) { return schedule(r, token, delayMillis); }
    public final boolean postAtTime(Runnable r, long uptimeMillis) { return schedule(r, null, uptimeMillis - SystemClock.uptimeMillis()); }

    public final boolean postAtTime(Runnable r, Object token, long uptimeMillis) {
        return schedule(r, token, uptimeMillis - SystemClock.uptimeMillis());
    }

    public final boolean postAtFrontOfQueue(Runnable r) { return post(r); }

    /** Takes back [r]'s pending posts. */
    public final void removeCallbacks(Runnable r) { remove(r, null); }

    /** Takes back [r]'s pending posts with [token]; with a null token, all of [r]'s. */
    public final void removeCallbacks(Runnable r, Object token) { remove(r, token); }

    /** Takes back the pending posts with [token]; with a null token, everything this handler holds. */
    public final void removeCallbacksAndMessages(Object token) { remove(null, token); }

    public final boolean hasCallbacks(Runnable r) {
        synchronized (pending) {
            for (Pending p : pending) if (p.task == r) return true;
            return false;
        }
    }

    public final Looper getLooper() { return Looper.getMainLooper(); }

    private boolean schedule(Runnable task, Object token, long delayMillis) {
        Pending post = new Pending(task, token);
        synchronized (pending) {
            pending.add(post);
            post.future = MainThread.schedule(() -> {
                // One taken back after its time came, but before it ran, doesn't run.
                synchronized (pending) {
                    if (!pending.remove(post)) return;
                }
                task.run();
            }, delayMillis);
        }
        return true;
    }

    private void remove(Runnable task, Object token) {
        synchronized (pending) {
            pending.removeIf(p -> {
                boolean match = (task == null || p.task == task) && (token == null || p.token == token);
                if (match) p.future.cancel(false);
                return match;
            });
        }
    }
}
