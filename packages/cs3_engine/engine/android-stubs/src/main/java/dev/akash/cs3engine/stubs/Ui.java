package dev.akash.cs3engine.stubs;

import android.view.View;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.WeakHashMap;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * The stand-in views' side of extension screens (the spec's "Windows" and "Changes"): the windows stand-in
 * dialogs show, which DialogFragment a dialog is, whether the screen changed since it was last read, and
 * whether the person (an action from the app) is the one changing it. The engine (JvmUiHost) listens.
 */
public final class Ui {
    /** The most items a list binds: part 1's cap on Android (a list of thousands would be all bound). */
    public static final int MAX_LIST_ITEMS = 500;

    /** A window a stand-in shows: a dialog's views. */
    public static final class Window {
        /** What shows it: a Dialog. */
        public final Object owner;
        /** Its views. */
        public final View root;
        /** sheet, alert or dialog. */
        public final String kind;
        /** The DialogFragment whose dialog it is, or null: its class says whose extension it is. */
        public final Object fragment;
        /** Where it was shown from: the extension's code, when neither its fragment nor its class says. */
        public final Throwable shownFrom;

        public Window(Object owner, View root, String kind, Object fragment) {
            this.owner = owner;
            this.root = root;
            this.kind = kind;
            this.fragment = fragment;
            this.shownFrom = new Throwable("window shown");
        }
    }

    /** Hears windows come and go, on the main thread. */
    public interface Listener {
        void shown(Window window);

        void dismissed(Window window);
    }

    private interface Telling {
        void to(Listener listener);
    }

    private static final List<Window> windows = new CopyOnWriteArrayList<>();
    private static final Map<Object, Object> fragments = Collections.synchronizedMap(new WeakHashMap<>());
    private static final AtomicBoolean dirty = new AtomicBoolean();
    private static final AtomicBoolean wakePosted = new AtomicBoolean();
    private static volatile Listener listener;
    private static volatile boolean personActing;

    private Ui() {}

    public static void setListener(Listener value) {
        listener = value;
    }

    /** [window] shows: registered at once; the listener hears on the main thread. */
    public static void shown(Window window) {
        windows.add(window);
        changed();
        tell(l -> l.shown(window));
    }

    /** [owner]'s window goes. */
    public static void dismissed(Object owner) {
        for (Window window : windows) {
            if (window.owner != owner) continue;
            windows.remove(window);
            changed();
            tell(l -> l.dismissed(window));
        }
    }

    public static List<Window> windows() {
        return new ArrayList<>(windows);
    }

    /** Whether [root] is a showing window's views. */
    public static boolean isShowing(View root) {
        for (Window window : windows) if (window.root == root) return true;
        return false;
    }

    /** [dialog] is [fragment]'s, a DialogFragment's: its window will say so. */
    public static void own(Object dialog, Object fragment) {
        fragments.put(dialog, fragment);
    }

    public static Object fragmentOf(Object dialog) {
        return fragments.get(dialog);
    }

    /**
     * A stand-in changed: the screen is read again after the main thread's current task. Off the main
     * thread (an extension's background work), the main thread is woken to do it.
     */
    public static void changed() {
        dirty.set(true);
        if (!MainThread.isMainThread() && wakePosted.compareAndSet(false, true)) MainThread.post(() -> wakePosted.set(false));
    }

    /** Whether anything changed since the last call. */
    public static boolean takeDirty() {
        return dirty.getAndSet(false);
    }

    /** Whether the person's action (from the app) is running: a slider's change is then the user's. */
    public static boolean personActing() {
        return personActing;
    }

    /** Runs [action] as the person's. Main thread. */
    public static void acting(Runnable action) {
        boolean before = personActing;
        personActing = true;
        try {
            action.run();
        } finally {
            personActing = before;
        }
    }

    private static void tell(Telling telling) {
        if (MainThread.isMainThread()) {
            Listener now = listener;
            if (now != null) telling.to(now);
        } else {
            MainThread.post(() -> {
                Listener now = listener;
                if (now != null) telling.to(now);
            });
        }
    }
}
