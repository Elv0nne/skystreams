package android.os;

import dev.akash.cs3engine.stubs.MainThread;

public final class Looper {
    private static final Looper MAIN = new Looper();

    private Looper() {}

    public static Looper getMainLooper() { return MAIN; }
    public static Looper myLooper() { return MainThread.isMainThread() ? MAIN : null; }
    public static void prepare() {}
    public static void loop() {}
    public Thread getThread() { return MainThread.thread(); }
    public boolean isCurrentThread() { return MainThread.isMainThread(); }
}
