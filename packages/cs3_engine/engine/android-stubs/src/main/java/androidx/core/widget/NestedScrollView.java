package androidx.core.widget;

import android.content.Context;
import android.util.AttributeSet;
import android.widget.FrameLayout;

/** AndroidX's scroll view: a frame (the sheet scrolls itself). */
public class NestedScrollView extends FrameLayout {
    public NestedScrollView(Context context) {
        this(context, null);
    }

    public NestedScrollView(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public NestedScrollView(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr, 0);
    }
}
