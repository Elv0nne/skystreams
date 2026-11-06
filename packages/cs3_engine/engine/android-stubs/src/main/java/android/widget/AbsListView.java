package android.widget;

import android.content.Context;
import android.database.DataSetObserver;
import android.util.AttributeSet;
import android.view.View;
import android.view.ViewGroup;
import dev.akash.cs3engine.stubs.Ui;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;

/**
 * A list: every item (at most 500) is bound as a child, on setAdapter and on each data change. A position
 * keeps its view (as convertView) while its type stays the same.
 */
public abstract class AbsListView extends AdapterView<ListAdapter> {
    public static final int CHOICE_MODE_NONE = 0;
    public static final int CHOICE_MODE_SINGLE = 1;
    public static final int CHOICE_MODE_MULTIPLE = 2;
    public static final int CHOICE_MODE_MULTIPLE_MODAL = 3;

    public static class LayoutParams extends ViewGroup.LayoutParams {
        public LayoutParams(Context c, AttributeSet attrs) {
            super(c, attrs);
        }

        public LayoutParams(int w, int h) {
            super(w, h);
        }

        public LayoutParams(int w, int h, int viewType) {
            super(w, h);
        }

        public LayoutParams(ViewGroup.LayoutParams source) {
            super(source);
        }
    }

    private ListAdapter adapter;
    private final List<Integer> types = new ArrayList<>();
    private int choiceMode = CHOICE_MODE_NONE;
    private final Set<Integer> checked = new TreeSet<>();

    private final DataSetObserver observer = new DataSetObserver() {
        @Override public void onChanged() { bind(); }
        @Override public void onInvalidated() { bind(); }
    };

    public AbsListView(Context context) {
        this(context, null);
    }

    public AbsListView(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public AbsListView(Context context, AttributeSet attrs, int defStyleAttr) {
        this(context, attrs, defStyleAttr, 0);
    }

    public AbsListView(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
    }

    @Override public ListAdapter getAdapter() { return adapter; }

    @Override public void setAdapter(ListAdapter adapter) {
        if (this.adapter != null) this.adapter.unregisterDataSetObserver(observer);
        this.adapter = adapter;
        checked.clear();
        removeAllViewsInLayout();
        types.clear();
        if (adapter != null) adapter.registerDataSetObserver(observer);
        bind();
    }

    private void bind() {
        List<View> previous = new ArrayList<>();
        for (int i = 0; i < getChildCount(); i++) previous.add(getChildAt(i));
        List<Integer> previousTypes = new ArrayList<>(types);
        removeAllViewsInLayout();
        types.clear();
        int count = adapter == null ? 0 : Math.min(adapter.getCount(), Ui.MAX_LIST_ITEMS);
        for (int i = 0; i < count; i++) {
            int type = adapter.getItemViewType(i);
            View convert = i < previous.size() && previousTypes.get(i) == type ? previous.get(i) : null;
            View view = adapter.getView(i, convert, this);
            ViewGroup.LayoutParams params = view.getLayoutParams();
            addViewInLayout(view, -1, params instanceof LayoutParams ? params : new LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT));
            types.add(type);
        }
        changed();
    }

    @Override public View getSelectedView() { return null; }
    @Override public void setSelection(int position) {}
    public void setChoiceMode(int choiceMode) { this.choiceMode = choiceMode; }
    public int getChoiceMode() { return choiceMode; }

    public void setItemChecked(int position, boolean value) {
        if (choiceMode == CHOICE_MODE_SINGLE && value) checked.clear();
        if (value) checked.add(position);
        else checked.remove(position);
        changed();
    }

    public boolean isItemChecked(int position) { return checked.contains(position); }
    public int getCheckedItemPosition() { return choiceMode == CHOICE_MODE_SINGLE && checked.size() == 1 ? checked.iterator().next() : INVALID_POSITION; }
    public int getCheckedItemCount() { return checked.size(); }

    public void clearChoices() {
        checked.clear();
        changed();
    }

    @Override public boolean performItemClick(View view, int position, long id) {
        if (choiceMode == CHOICE_MODE_SINGLE) setItemChecked(position, true);
        else if (choiceMode == CHOICE_MODE_MULTIPLE || choiceMode == CHOICE_MODE_MULTIPLE_MODAL) setItemChecked(position, !isItemChecked(position));
        return super.performItemClick(view, position, id) || choiceMode != CHOICE_MODE_NONE;
    }

    @Override protected ViewGroup.LayoutParams generateDefaultLayoutParams() {
        return new LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT, 0);
    }
}
