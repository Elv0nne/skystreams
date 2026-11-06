package android.widget;

/** A list's items, some perhaps disabled. */
public interface ListAdapter extends Adapter {
    boolean areAllItemsEnabled();
    boolean isEnabled(int position);
}
