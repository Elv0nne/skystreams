package androidx.recyclerview.widget;

import android.content.Context;
import android.util.AttributeSet;

/** A row or column of items: its orientation; every item is bound anyway. */
public class LinearLayoutManager extends RecyclerView.LayoutManager {
    public static final int HORIZONTAL = RecyclerView.HORIZONTAL;
    public static final int VERTICAL = RecyclerView.VERTICAL;

    private int orientation;
    private boolean reverseLayout;
    private boolean stackFromEnd;

    public LinearLayoutManager(Context context) {
        this(context, VERTICAL, false);
    }

    public LinearLayoutManager(Context context, int orientation, boolean reverseLayout) {
        this.orientation = orientation;
        this.reverseLayout = reverseLayout;
    }

    public LinearLayoutManager(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        this(context, VERTICAL, false);
    }

    @Override public RecyclerView.LayoutParams generateDefaultLayoutParams() {
        return new RecyclerView.LayoutParams(RecyclerView.LayoutParams.WRAP_CONTENT, RecyclerView.LayoutParams.WRAP_CONTENT);
    }

    public int getOrientation() { return orientation; }
    public void setOrientation(int orientation) { this.orientation = orientation; }
    public boolean getReverseLayout() { return reverseLayout; }
    public void setReverseLayout(boolean reverseLayout) { this.reverseLayout = reverseLayout; }
    public boolean getStackFromEnd() { return stackFromEnd; }
    public void setStackFromEnd(boolean stackFromEnd) { this.stackFromEnd = stackFromEnd; }
    @Override public boolean canScrollHorizontally() { return orientation == HORIZONTAL; }
    @Override public boolean canScrollVertically() { return orientation == VERTICAL; }
    public int findFirstVisibleItemPosition() { return getItemCount() == 0 ? RecyclerView.NO_POSITION : 0; }
    public int findFirstCompletelyVisibleItemPosition() { return findFirstVisibleItemPosition(); }
    public int findLastVisibleItemPosition() { return Math.min(getItemCount(), getChildCount()) - 1; }
    public int findLastCompletelyVisibleItemPosition() { return findLastVisibleItemPosition(); }
    public void scrollToPositionWithOffset(int position, int offset) {}
}
