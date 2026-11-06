package android.widget;

import android.content.Context;
import android.util.AttributeSet;
import dev.akash.cs3engine.stubs.LayoutAttributes;

/** A stand-in list view. */
public class ListView extends AbsListView {
    public ListView(Context context) {
        this(context, null);
    }

    public ListView(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public ListView(Context context, AttributeSet attrs, int defStyleAttr) {
        this(context, attrs, defStyleAttr, 0);
    }

    public ListView(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
        LayoutAttributes.entries(this, attrs);
    }
}
