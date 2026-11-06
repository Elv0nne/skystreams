package android.widget;

import android.database.DataSetObserver;
import android.view.View;
import android.view.ViewGroup;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/** An adapter's common part: its observers, and Android's defaults. */
public abstract class BaseAdapter implements ListAdapter, SpinnerAdapter {
    private final List<DataSetObserver> observers = new CopyOnWriteArrayList<>();

    @Override public boolean hasStableIds() { return false; }
    @Override public void registerDataSetObserver(DataSetObserver observer) { observers.add(observer); }
    @Override public void unregisterDataSetObserver(DataSetObserver observer) { observers.remove(observer); }

    public void notifyDataSetChanged() {
        for (DataSetObserver observer : observers) observer.onChanged();
    }

    public void notifyDataSetInvalidated() {
        for (DataSetObserver observer : observers) observer.onInvalidated();
    }

    @Override public boolean areAllItemsEnabled() { return true; }
    @Override public boolean isEnabled(int position) { return true; }
    @Override public View getDropDownView(int position, View convertView, ViewGroup parent) { return getView(position, convertView, parent); }
    @Override public int getItemViewType(int position) { return 0; }
    @Override public int getViewTypeCount() { return 1; }
    @Override public boolean isEmpty() { return getCount() == 0; }
}
