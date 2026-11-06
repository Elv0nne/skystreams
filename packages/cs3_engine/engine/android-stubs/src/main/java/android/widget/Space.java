package android.widget;

import android.content.Context;
import android.util.AttributeSet;
import android.view.View;

/** Room in a layout: invisible, as Android's is. */
public final class Space extends View {
    public Space(Context context) {
        this(context, null);
    }

    public Space(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public Space(Context context, AttributeSet attrs, int defStyleAttr) {
        this(context, attrs, defStyleAttr, 0);
    }

    public Space(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
        if (getVisibility() == VISIBLE) setVisibility(INVISIBLE);
    }
}
