package android.widget;

import android.content.Context;
import android.database.DataSetObserver;
import android.util.AttributeSet;
import android.view.View;
import dev.akash.cs3engine.stubs.LayoutAttributes;
import dev.akash.cs3engine.stubs.MainThread;

/**
 * A stand-in dropdown: its adapter and selection (the sheet's own menu is the dropdown). As Android's, the
 * first item is selected when the adapter comes, and the listener hears the settled selection once, after
 * the current main-thread task.
 */
public class Spinner extends AdapterView<SpinnerAdapter> {
    public static final int MODE_DIALOG = 0;
    public static final int MODE_DROPDOWN = 1;

    private SpinnerAdapter adapter;
    private int selected = INVALID_POSITION;
    private int heard = INVALID_POSITION;
    private boolean telling;
    private CharSequence prompt;
    private View selectedView;
    private int selectedViewFor = INVALID_POSITION;

    private final DataSetObserver observer = new DataSetObserver() {
        @Override public void onChanged() {
            selectedViewFor = INVALID_POSITION;
            int count = adapter == null ? 0 : adapter.getCount();
            if (count == 0) select(INVALID_POSITION);
            else if (selected == INVALID_POSITION || selected >= count) select(0);
            changed();
        }
    };

    public Spinner(Context context) {
        this(context, (AttributeSet) null);
    }

    public Spinner(Context context, int mode) {
        this(context, null);
    }

    public Spinner(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public Spinner(Context context, AttributeSet attrs, int defStyleAttr) {
        this(context, attrs, defStyleAttr, 0);
    }

    public Spinner(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
        LayoutAttributes.entries(this, attrs);
    }

    public Spinner(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes, int mode) {
        this(context, attrs, defStyleAttr, defStyleRes);
    }

    @Override public SpinnerAdapter getAdapter() { return adapter; }

    @Override public void setAdapter(SpinnerAdapter adapter) {
        if (this.adapter != null) this.adapter.unregisterDataSetObserver(observer);
        this.adapter = adapter;
        if (adapter != null) adapter.registerDataSetObserver(observer);
        selected = INVALID_POSITION;
        selectedView = null;
        selectedViewFor = INVALID_POSITION;
        select(adapter != null && adapter.getCount() > 0 ? 0 : INVALID_POSITION);
        changed();
    }

    @Override public void setSelection(int position) { select(position); }
    public void setSelection(int position, boolean animate) { select(position); }
    @Override public int getSelectedItemPosition() { return selected; }

    /**
     * The selected item's view, made by the adapter as Android's spinner shows it (never added: nothing is drawn).
     * Listeners get it, and Kotlin ones may declare it non-null.
     */
    @Override public View getSelectedView() {
        if (adapter == null || selected == INVALID_POSITION) return null;
        if (selectedViewFor != selected) {
            selectedView = adapter.getView(selected, selectedView, this);
            selectedViewFor = selected;
        }
        return selectedView;
    }

    private void select(int position) {
        int count = adapter == null ? 0 : adapter.getCount();
        if (position != INVALID_POSITION && (position < 0 || position >= count)) return;
        if (position == selected) return;
        selected = position;
        changed();
        if (telling) return;
        telling = true;
        MainThread.post(() -> {
            telling = false;
            tell();
        });
    }

    private void tell() {
        if (selected == heard) return;
        heard = selected;
        OnItemSelectedListener listener = getOnItemSelectedListener();
        if (listener == null) return;
        if (selected == INVALID_POSITION) listener.onNothingSelected(this);
        else listener.onItemSelected(this, getSelectedView(), selected, getItemIdAtPosition(selected));
    }

    /** The sheet's dropdown is the menu: a tap here opens nothing. */
    @Override public boolean performClick() { return true; }
    public void setPrompt(CharSequence prompt) { this.prompt = prompt; }
    public CharSequence getPrompt() { return prompt; }
}
