package androidx.recyclerview.widget;

import android.content.Context;
import android.util.AttributeSet;

/** A staggered grid: its span count and orientation. */
public class StaggeredGridLayoutManager extends RecyclerView.LayoutManager {
    public static final int HORIZONTAL = RecyclerView.HORIZONTAL;
    public static final int VERTICAL = RecyclerView.VERTICAL;

    private int spanCount;
    private int orientation;

    public StaggeredGridLayoutManager(int spanCount, int orientation) {
        this.spanCount = spanCount;
        this.orientation = orientation;
    }

    public StaggeredGridLayoutManager(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        this(1, VERTICAL);
    }

    @Override public RecyclerView.LayoutParams generateDefaultLayoutParams() {
        return orientation == HORIZONTAL
            ? new RecyclerView.LayoutParams(RecyclerView.LayoutParams.WRAP_CONTENT, RecyclerView.LayoutParams.MATCH_PARENT)
            : new RecyclerView.LayoutParams(RecyclerView.LayoutParams.MATCH_PARENT, RecyclerView.LayoutParams.WRAP_CONTENT);
    }

    public int getSpanCount() { return spanCount; }
    public void setSpanCount(int spanCount) { this.spanCount = spanCount; }
    public int getOrientation() { return orientation; }
    public void setOrientation(int orientation) { this.orientation = orientation; }
}
