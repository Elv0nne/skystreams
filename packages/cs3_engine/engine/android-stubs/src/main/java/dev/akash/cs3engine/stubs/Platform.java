package dev.akash.cs3engine.stubs;

import android.content.Context;
import android.content.Intent;

/**
 * What the stand-ins need from the engine they run in (the JVM engine's JvmPlatform sets it): what Android
 * would show itself (links, toasts, the clipboard), exits, and main-thread crashes. Until it's set, nothing
 * leaves the stand-ins, and an exit still stops the code that asked for it.
 */
public final class Platform {
    public interface Host {
        /** [context] started [intent]: a link, the app's restart, anything else. A restart throws. */
        void startActivity(Context context, Intent intent);

        /** A toast's text, for the app to show. */
        void toast(CharSequence text);

        /** Text put on the clipboard, for the app to copy. */
        void copy(CharSequence text);

        /** An extension asked to end the process: this throws, so the code that asked stops there. */
        void exit(int status);

        /** A task on the main thread threw [error]; the main thread runs on. */
        void uncaught(Throwable error);
    }

    private static final Host NONE = new Host() {
        @Override public void startActivity(Context context, Intent intent) {}
        @Override public void toast(CharSequence text) {}
        @Override public void copy(CharSequence text) {}

        @Override public void exit(int status) {
            throw new IllegalStateException("exit(" + status + ") blocked: an exit would end the engine");
        }

        @Override public void uncaught(Throwable error) {
            System.err.println("[cs3-main] task failed: " + error);
        }
    };

    private static volatile Host host = NONE;

    private Platform() {}

    public static Host host() {
        return host;
    }

    /** Installs [value]; null restores the inert default. */
    public static void install(Host value) {
        host = value == null ? NONE : value;
    }
}
