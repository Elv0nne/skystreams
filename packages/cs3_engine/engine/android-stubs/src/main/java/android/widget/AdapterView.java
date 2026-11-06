package android.widget;

import android.content.Context;
import android.util.AttributeSet;
import android.view.View;
import android.view.ViewGroup;

/** A view whose children come from its adapter: they can't be added by hand, as on Android. */
public abstract class AdapterView<T extends Adapter> extends ViewGroup {
    public static final int INVALID_POSITION = -1;
    public static final long INVALID_ROW_ID = Long.MIN_VALUE;
    public static final int ITEM_VIEW_TYPE_IGNORE = -1;
    public static final int ITEM_VIEW_TYPE_HEADER_OR_FOOTER = -2;

    public interface OnItemClickListener {
        void onItemClick(AdapterView<?> parent, View view, int position, long id);
    }

    public interface OnItemLongClickListener {
        boolean onItemLongClick(AdapterView<?> parent, View view, int position, long id);
    }

    public interface OnItemSelectedListener {
        void onItemSelected(AdapterView<?> parent, View view, int position, long id);

        void onNothingSelected(AdapterView<?> parent);
    }

    private OnItemClickListener onItemClick;
    private OnItemLongClickListener onItemLongClick;
    private OnItemSelectedListener onItemSelected;

    public AdapterView(Context context) {
        this(context, null);
    }

    public AdapterView(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public AdapterView(Context context, AttributeSet attrs, int defStyleAttr) {
        this(context, attrs, defStyleAttr, 0);
    }

    public AdapterView(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
    }

    public abstract T getAdapter();
    public abstract void setAdapter(T adapter);
    public abstract View getSelectedView();
    public abstract void setSelection(int position);

    public int getSelectedItemPosition() { return INVALID_POSITION; }

    public long getSelectedItemId() {
        int position = getSelectedItemPosition();
        return position == INVALID_POSITION ? INVALID_ROW_ID : getItemIdAtPosition(position);
    }

    public Object getSelectedItem() {
        int position = getSelectedItemPosition();
        return position == INVALID_POSITION ? null : getItemAtPosition(position);
    }

    public int getCount() {
        T adapter = getAdapter();
        return adapter == null ? 0 : adapter.getCount();
    }

    public Object getItemAtPosition(int position) {
        T adapter = getAdapter();
        return adapter == null || position < 0 ? null : adapter.getItem(position);
    }

    public long getItemIdAtPosition(int position) {
        T adapter = getAdapter();
        return adapter == null || position < 0 ? INVALID_ROW_ID : adapter.getItemId(position);
    }

    /** The item [view] is, or is inside; INVALID_POSITION when it's in none. */
    public int getPositionForView(View view) {
        View child = view;
        while (child != null && child.getParent() != this) {
            child = child.getParent() instanceof View ? (View) child.getParent() : null;
        }
        return child == null ? INVALID_POSITION : indexOfChild(child) + getFirstVisiblePosition();
    }

    public int getFirstVisiblePosition() { return 0; }
    public int getLastVisiblePosition() { return getChildCount() - 1; }
    public void setOnItemClickListener(OnItemClickListener listener) { onItemClick = listener; }
    public final OnItemClickListener getOnItemClickListener() { return onItemClick; }
    public void setOnItemLongClickListener(OnItemLongClickListener listener) { onItemLongClick = listener; }
    public final OnItemLongClickListener getOnItemLongClickListener() { return onItemLongClick; }
    public void setOnItemSelectedListener(OnItemSelectedListener listener) { onItemSelected = listener; }
    public final OnItemSelectedListener getOnItemSelectedListener() { return onItemSelected; }

    public boolean performItemClick(View view, int position, long id) {
        if (onItemClick == null) return false;
        onItemClick.onItemClick(this, view, position, id);
        return true;
    }

    @Override public void addView(View child) { throw new UnsupportedOperationException("addView(View) is not supported in AdapterView"); }
    @Override public void addView(View child, int index) { throw new UnsupportedOperationException("addView(View, int) is not supported in AdapterView"); }
    @Override public void addView(View child, ViewGroup.LayoutParams params) { throw new UnsupportedOperationException("addView(View, LayoutParams) is not supported in AdapterView"); }
    @Override public void addView(View child, int index, ViewGroup.LayoutParams params) { throw new UnsupportedOperationException("addView(View, int, LayoutParams) is not supported in AdapterView"); }
    @Override public void removeView(View child) { throw new UnsupportedOperationException("removeView(View) is not supported in AdapterView"); }
    @Override public void removeViewAt(int index) { throw new UnsupportedOperationException("removeViewAt(int) is not supported in AdapterView"); }
    @Override public void removeAllViews() { throw new UnsupportedOperationException("removeAllViews() is not supported in AdapterView"); }
    @Override protected void onLayout(boolean changed, int l, int t, int r, int b) {}
}
