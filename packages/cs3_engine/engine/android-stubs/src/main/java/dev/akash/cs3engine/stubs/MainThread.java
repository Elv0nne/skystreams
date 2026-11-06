package dev.akash.cs3engine.stubs;

import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

/**
 * The engine's stand-in for Android's main (UI) thread. {@code Handler}, {@code Looper},
 * {@code Activity.runOnUiThread} and the coroutines Main dispatcher all post here.
 */
public final class MainThread {
    private static volatile Thread thread;
    private static volatile Runnable afterTask;
    private static final ScheduledExecutorService EXECUTOR = Executors.newSingleThreadScheduledExecutor(r -> {
        Thread t = new Thread(r, "cs3-main");
        t.setDaemon(true);
        thread = t;
        return t;
    });

    private MainThread() {}

    public static void post(Runnable task) {
        EXECUTOR.execute(guard(task));
    }

    public static void postDelayed(Runnable task, long delayMillis) {
        EXECUTOR.schedule(guard(task), Math.max(0, delayMillis), TimeUnit.MILLISECONDS);
    }

    /** Runs [task] on the main thread after [delayMillis]; its future takes it back (Handler.removeCallbacks). */
    public static Future<?> schedule(Runnable task, long delayMillis) {
        return EXECUTOR.schedule(guard(task), Math.max(0, delayMillis), TimeUnit.MILLISECONDS);
    }

    public static boolean isMainThread() {
        return Thread.currentThread() == thread;
    }

    public static Thread thread() {
        return thread;
    }

    /** Runs [hook] on the main thread after each of its tasks (extension screens are read then); null for none. */
    public static void setAfterTask(Runnable hook) {
        afterTask = hook;
    }

    // A throwing UI task must not kill the only main thread: the platform hears of it (an extension's
    // crash ends its screen), and the after-task hook runs either way.
    private static Runnable guard(Runnable task) {
        return () -> {
            try {
                task.run();
            } catch (Throwable t) {
                try {
                    Platform.host().uncaught(t);
                } catch (Throwable reported) {
                    System.err.println("[cs3-main] task failed: " + t + "; reporting it failed: " + reported);
                }
            } finally {
                Runnable hook = afterTask;
                if (hook != null) {
                    try {
                        hook.run();
                    } catch (Throwable t) {
                        System.err.println("[cs3-main] after-task hook failed: " + t);
                    }
                }
            }
        };
    }
}
