package android.widget;

import android.content.Context;
import android.util.AttributeSet;
import dev.akash.cs3engine.stubs.LayoutAttributes;

/** A stand-in button: a text view that takes taps. */
public class Button extends TextView {
    public Button(Context context) {
        this(context, null);
    }

    public Button(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public Button(Context context, AttributeSet attrs, int defStyleAttr) {
        this(context, attrs, defStyleAttr, 0);
    }

    public Button(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
        setClickable(true);
        // Clickable by default: the layout's view attributes again, so they win, as on Android.
        LayoutAttributes.view(this, attrs);
    }
}
