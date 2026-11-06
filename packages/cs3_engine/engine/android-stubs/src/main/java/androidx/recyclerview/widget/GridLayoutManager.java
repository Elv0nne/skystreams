package androidx.recyclerview.widget;

import android.content.Context;
import android.util.AttributeSet;

/** A grid of items: its span count (at least 1, as Android's) and span sizes. */
public class GridLayoutManager extends LinearLayoutManager {
    public static final int DEFAULT_SPAN_COUNT = -1;

    public abstract static class SpanSizeLookup {
        public abstract int getSpanSize(int position);
    }

    public static final class DefaultSpanSizeLookup extends SpanSizeLookup {
        @Override public int getSpanSize(int position) { return 1; }
    }

    private int spanCount = 1;
    private SpanSizeLookup spanSizeLookup = new DefaultSpanSizeLookup();

    public GridLayoutManager(Context context, int spanCount) {
        super(context);
        setSpanCount(spanCount);
    }

    public GridLayoutManager(Context context, int spanCount, int orientation, boolean reverseLayout) {
        super(context, orientation, reverseLayout);
        setSpanCount(spanCount);
    }

    public GridLayoutManager(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
    }

    public int getSpanCount() { return spanCount; }

    public void setSpanCount(int spanCount) {
        if (spanCount < 1) throw new IllegalArgumentException("Span count should be at least 1. Provided " + spanCount);
        this.spanCount = spanCount;
    }

    public void setSpanSizeLookup(SpanSizeLookup spanSizeLookup) { this.spanSizeLookup = spanSizeLookup; }
    public SpanSizeLookup getSpanSizeLookup() { return spanSizeLookup; }
}
