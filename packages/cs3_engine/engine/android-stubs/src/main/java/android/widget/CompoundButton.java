package android.widget;

import android.content.Context;
import android.graphics.drawable.Drawable;
import android.util.AttributeSet;
import dev.akash.cs3engine.stubs.LayoutAttributes;

/** A stand-in two-state button: a tap toggles it, then clicks; its listener hears each change once. */
public abstract class CompoundButton extends Button implements Checkable {
    public interface OnCheckedChangeListener {
        void onCheckedChanged(CompoundButton buttonView, boolean isChecked);
    }

    private boolean checked;
    private boolean broadcasting;
    private OnCheckedChangeListener listener;
    private OnCheckedChangeListener groupListener;

    public CompoundButton(Context context) {
        this(context, null);
    }

    public CompoundButton(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public CompoundButton(Context context, AttributeSet attrs, int defStyleAttr) {
        this(context, attrs, defStyleAttr, 0);
    }

    public CompoundButton(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
        LayoutAttributes.checked(this, attrs);
    }

    @Override public boolean isChecked() { return checked; }

    @Override public void setChecked(boolean checked) {
        if (this.checked == checked) return;
        this.checked = checked;
        changed();
        // As Android's: a listener that changes the state again doesn't recurse.
        if (broadcasting) return;
        broadcasting = true;
        try {
            if (listener != null) listener.onCheckedChanged(this, this.checked);
            if (groupListener != null) groupListener.onCheckedChanged(this, this.checked);
        } finally {
            broadcasting = false;
        }
    }

    @Override public void toggle() { setChecked(!checked); }

    @Override public boolean performClick() {
        toggle();
        return super.performClick();
    }

    public void setOnCheckedChangeListener(OnCheckedChangeListener listener) { this.listener = listener; }

    /** Its radio group's own listener, beside the extension's. */
    void setGroupListener(OnCheckedChangeListener listener) { groupListener = listener; }

    public void setButtonDrawable(int resId) {}
    public void setButtonDrawable(Drawable drawable) {}
}
