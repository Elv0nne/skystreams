package android.os;

public final class SystemClock {
    private SystemClock() {}

    // Counted, as Android's are, from the device's start: the JVM's monotonic clock counts from there on every host the
    // engine runs on (mach_absolute_time on macOS and iOS, CLOCK_MONOTONIC on Linux, QueryPerformanceCounter on
    // Windows). A clock from its own first use read 0 for the first Back of an engine run.
    public static long elapsedRealtime() { return System.nanoTime() / 1_000_000L; }
    public static long elapsedRealtimeNanos() { return System.nanoTime(); }
    public static long uptimeMillis() { return elapsedRealtime(); }
    public static long currentThreadTimeMillis() { return elapsedRealtime(); }

    public static void sleep(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
