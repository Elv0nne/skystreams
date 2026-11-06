package android.text;

import android.graphics.Paint;

/** A text view's paint. */
public class TextPaint extends Paint {
    public TextPaint() {}

    public TextPaint(int flags) {
        super(flags);
    }

    public TextPaint(Paint p) {
        super(p);
    }
}
