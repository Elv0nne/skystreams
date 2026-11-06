package androidx.appcompat.widget;

import android.content.Context;
import android.util.AttributeSet;
import android.widget.CompoundButton;

/** AppCompat's switch, which Material's switches extend. */
public class SwitchCompat extends CompoundButton {
    public SwitchCompat(Context context) {
        this(context, null);
    }

    public SwitchCompat(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public SwitchCompat(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr, 0);
    }
}
