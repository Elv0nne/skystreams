package android.widget;

import android.content.Context;
import android.util.AttributeSet;
import dev.akash.cs3engine.stubs.LayoutAttributes;
import dev.akash.cs3engine.stubs.Ui;

/**
 * A stand-in slider. The person's slide (an action from the app) reaches the extension as a drag would:
 * start, change with fromUser, stop. Any other change is the extension's own.
 */
public class SeekBar extends ProgressBar {
    public interface OnSeekBarChangeListener {
        void onProgressChanged(SeekBar seekBar, int progress, boolean fromUser);

        void onStartTrackingTouch(SeekBar seekBar);

        void onStopTrackingTouch(SeekBar seekBar);
    }

    private OnSeekBarChangeListener listener;

    public SeekBar(Context context) {
        this(context, null);
    }

    public SeekBar(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public SeekBar(Context context, AttributeSet attrs, int defStyleAttr) {
        this(context, attrs, defStyleAttr, 0);
    }

    public SeekBar(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
        setIndeterminate(false);
        // Not indeterminate: the layout's range and value again, which an indeterminate bar dropped.
        LayoutAttributes.progress(this, attrs);
    }

    public void setOnSeekBarChangeListener(OnSeekBarChangeListener listener) { this.listener = listener; }

    @Override public synchronized void setProgress(int progress) {
        if (!Ui.personActing()) {
            super.setProgress(progress);
            return;
        }
        if (listener != null) listener.onStartTrackingTouch(this);
        setProgressInternal(progress, true);
        if (listener != null) listener.onStopTrackingTouch(this);
    }

    @Override void onProgressRefresh(int progress, boolean fromUser) {
        if (listener != null) listener.onProgressChanged(this, progress, fromUser);
    }
}
