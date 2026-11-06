package android.widget;

import android.content.Context;
import android.util.AttributeSet;
import android.view.View;
import dev.akash.cs3engine.stubs.LayoutAttributes;

/** A stand-in progress bar: indeterminate by default, as Android's default style is; else its range and progress. */
public class ProgressBar extends View {
    private int min;
    private int max = 100;
    private int progress;
    private int secondaryProgress;
    private boolean indeterminate = true;

    public ProgressBar(Context context) {
        this(context, null);
    }

    public ProgressBar(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public ProgressBar(Context context, AttributeSet attrs, int defStyleAttr) {
        this(context, attrs, defStyleAttr, 0);
    }

    public ProgressBar(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
        LayoutAttributes.progress(this, attrs);
    }

    public synchronized boolean isIndeterminate() { return indeterminate; }

    public synchronized void setIndeterminate(boolean indeterminate) {
        if (this.indeterminate == indeterminate) return;
        this.indeterminate = indeterminate;
        changed();
    }

    public synchronized int getProgress() { return indeterminate ? 0 : progress; }
    public synchronized void setProgress(int progress) { setProgressInternal(progress, false); }
    public void setProgress(int progress, boolean animate) { setProgress(progress); }
    public synchronized int getSecondaryProgress() { return secondaryProgress; }
    public synchronized void setSecondaryProgress(int secondaryProgress) { this.secondaryProgress = secondaryProgress; }
    public synchronized final void incrementProgressBy(int diff) { setProgress(progress + diff); }
    public synchronized int getMax() { return max; }

    public synchronized void setMax(int max) {
        if (max < min) max = min;
        if (max == this.max) return;
        this.max = max;
        changed();
        if (progress > max) setProgressInternal(max, false);
    }

    public synchronized int getMin() { return min; }

    public synchronized void setMin(int min) {
        if (min > max) min = max;
        if (min == this.min) return;
        this.min = min;
        changed();
        if (progress < min) setProgressInternal(min, false);
    }

    /** Sets [progress] (clamped to the range); the bar's own hook hears whether the person moved it. */
    synchronized boolean setProgressInternal(int progress, boolean fromUser) {
        if (indeterminate) return false;
        int clamped = Math.max(min, Math.min(max, progress));
        if (clamped == this.progress) return false;
        this.progress = clamped;
        changed();
        onProgressRefresh(clamped, fromUser);
        return true;
    }

    void onProgressRefresh(int progress, boolean fromUser) {}
}
