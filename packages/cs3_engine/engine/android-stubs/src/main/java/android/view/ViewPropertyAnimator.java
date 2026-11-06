package android.view;

import dev.akash.cs3engine.stubs.MainThread;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * A view's animator. Nothing moves over time: the targets apply, and the start and end actions run, when it
 * starts (when asked, or after the main thread's current task, as Android starts one on the next frame).
 */
public class ViewPropertyAnimator {
    private final View view;
    private final Map<String, Float> targets = new LinkedHashMap<>();
    private final List<Runnable> startActions = new ArrayList<>();
    private final List<Runnable> endActions = new ArrayList<>();
    private long duration = 300;
    private long startDelay;
    private boolean scheduled;

    ViewPropertyAnimator(View view) {
        this.view = view;
    }

    private ViewPropertyAnimator target(String property, float value) {
        targets.put(property, value);
        if (!scheduled) {
            scheduled = true;
            MainThread.post(() -> {
                if (scheduled) start();
            });
        }
        return this;
    }

    public ViewPropertyAnimator alpha(float value) { return target("alpha", value); }
    public ViewPropertyAnimator alphaBy(float value) { return target("alpha", view.getAlpha() + value); }
    public ViewPropertyAnimator translationX(float value) { return target("translationX", value); }
    public ViewPropertyAnimator translationY(float value) { return target("translationY", value); }
    public ViewPropertyAnimator translationXBy(float value) { return target("translationX", view.getTranslationX() + value); }
    public ViewPropertyAnimator translationYBy(float value) { return target("translationY", view.getTranslationY() + value); }
    public ViewPropertyAnimator x(float value) { return target("translationX", value); }
    public ViewPropertyAnimator y(float value) { return target("translationY", value); }
    public ViewPropertyAnimator scaleX(float value) { return target("scaleX", value); }
    public ViewPropertyAnimator scaleY(float value) { return target("scaleY", value); }
    public ViewPropertyAnimator rotation(float value) { return target("rotation", value); }
    public ViewPropertyAnimator setDuration(long duration) { this.duration = duration; return this; }
    public long getDuration() { return duration; }
    public ViewPropertyAnimator setStartDelay(long startDelay) { this.startDelay = startDelay; return this; }
    public long getStartDelay() { return startDelay; }
    public ViewPropertyAnimator withLayer() { return this; }
    public ViewPropertyAnimator withStartAction(Runnable runnable) { startActions.add(runnable); return this; }
    public ViewPropertyAnimator withEndAction(Runnable runnable) { endActions.add(runnable); return this; }

    public void start() {
        scheduled = false;
        for (Map.Entry<String, Float> target : targets.entrySet()) {
            float value = target.getValue();
            switch (target.getKey()) {
                case "alpha": view.setAlpha(value); break;
                case "translationX": view.setTranslationX(value); break;
                case "translationY": view.setTranslationY(value); break;
                case "scaleX": view.setScaleX(value); break;
                case "scaleY": view.setScaleY(value); break;
                case "rotation": view.setRotation(value); break;
                default: break;
            }
        }
        targets.clear();
        List<Runnable> starting = new ArrayList<>(startActions);
        List<Runnable> ending = new ArrayList<>(endActions);
        startActions.clear();
        endActions.clear();
        starting.forEach(Runnable::run);
        ending.forEach(Runnable::run);
    }

    public void cancel() {
        scheduled = false;
        targets.clear();
        startActions.clear();
        endActions.clear();
    }
}
