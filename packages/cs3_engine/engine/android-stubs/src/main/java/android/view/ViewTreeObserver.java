package android.view;

import dev.akash.cs3engine.stubs.MainThread;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * A view tree's observer. There's no layout pass: a global layout or pre-draw listener is heard once,
 * after the main thread's current task, as after a first layout. A listener reading sizes the stand-ins
 * don't have (0) may throw; that's logged, never the screen's end.
 */
public final class ViewTreeObserver {
    public interface OnGlobalLayoutListener {
        void onGlobalLayout();
    }

    public interface OnPreDrawListener {
        boolean onPreDraw();
    }

    public interface OnScrollChangedListener {
        void onScrollChanged();
    }

    public interface OnGlobalFocusChangeListener {
        void onGlobalFocusChanged(View oldFocus, View newFocus);
    }

    public interface OnWindowFocusChangeListener {
        void onWindowFocusChanged(boolean hasFocus);
    }

    public interface OnDrawListener {
        void onDraw();
    }

    private final List<OnGlobalLayoutListener> layouts = new CopyOnWriteArrayList<>();
    private final List<OnPreDrawListener> preDraws = new CopyOnWriteArrayList<>();

    ViewTreeObserver() {}

    public boolean isAlive() { return true; }

    public void addOnGlobalLayoutListener(OnGlobalLayoutListener listener) {
        layouts.add(listener);
        MainThread.post(() -> {
            if (layouts.contains(listener)) quietly(listener::onGlobalLayout);
        });
    }

    public void removeOnGlobalLayoutListener(OnGlobalLayoutListener listener) { layouts.remove(listener); }

    @Deprecated
    public void removeGlobalOnLayoutListener(OnGlobalLayoutListener listener) { removeOnGlobalLayoutListener(listener); }

    public void addOnPreDrawListener(OnPreDrawListener listener) {
        preDraws.add(listener);
        MainThread.post(() -> {
            if (preDraws.contains(listener)) quietly(listener::onPreDraw);
        });
    }

    public void removeOnPreDrawListener(OnPreDrawListener listener) { preDraws.remove(listener); }
    public void addOnScrollChangedListener(OnScrollChangedListener listener) {}
    public void removeOnScrollChangedListener(OnScrollChangedListener listener) {}
    public void addOnGlobalFocusChangeListener(OnGlobalFocusChangeListener listener) {}
    public void removeOnGlobalFocusChangeListener(OnGlobalFocusChangeListener listener) {}
    public void addOnWindowFocusChangeListener(OnWindowFocusChangeListener listener) {}
    public void removeOnWindowFocusChangeListener(OnWindowFocusChangeListener listener) {}
    public void addOnDrawListener(OnDrawListener listener) {}
    public void removeOnDrawListener(OnDrawListener listener) {}

    public void dispatchOnGlobalLayout() {
        for (OnGlobalLayoutListener listener : layouts) quietly(listener::onGlobalLayout);
    }

    public boolean dispatchOnPreDraw() {
        for (OnPreDrawListener listener : preDraws) quietly(listener::onPreDraw);
        return true;
    }

    private static void quietly(Runnable call) {
        try {
            call.run();
        } catch (RuntimeException e) {
            System.err.println("[cs3] a layout listener failed on the stand-ins' zero sizes: " + e);
        }
    }
}
