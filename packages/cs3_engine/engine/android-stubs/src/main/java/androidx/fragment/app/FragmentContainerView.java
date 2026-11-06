package androidx.fragment.app;

import android.content.Context;
import android.util.AttributeSet;
import android.widget.FrameLayout;

/** A frame that holds fragments' views: a transaction finds it by its id. */
public final class FragmentContainerView extends FrameLayout {
    public FragmentContainerView(Context context) {
        super(context);
    }

    public FragmentContainerView(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    public FragmentContainerView(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
    }
}
