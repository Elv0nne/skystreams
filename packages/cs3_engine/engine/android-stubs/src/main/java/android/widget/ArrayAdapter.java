package android.widget;

import android.content.Context;
import android.view.View;
import android.view.ViewGroup;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;

/**
 * Items as text. Each item's view is a TextView with its text: the layouts extensions name are Android's
 * (simple_spinner_item, simple_list_item_1…), which the sheet doesn't need.
 */
public class ArrayAdapter<T> extends BaseAdapter {
    private final Context context;
    private final List<T> objects;
    private boolean notifyOnChange = true;

    public ArrayAdapter(Context context, int resource) {
        this(context, resource, 0, new ArrayList<>());
    }

    public ArrayAdapter(Context context, int resource, int textViewResourceId) {
        this(context, resource, textViewResourceId, new ArrayList<>());
    }

    public ArrayAdapter(Context context, int resource, T[] objects) {
        this(context, resource, 0, Arrays.asList(objects));
    }

    public ArrayAdapter(Context context, int resource, int textViewResourceId, T[] objects) {
        this(context, resource, textViewResourceId, Arrays.asList(objects));
    }

    public ArrayAdapter(Context context, int resource, List<T> objects) {
        this(context, resource, 0, objects);
    }

    public ArrayAdapter(Context context, int resource, int textViewResourceId, List<T> objects) {
        this.context = context;
        this.objects = objects;
    }

    public static ArrayAdapter<CharSequence> createFromResource(Context context, int textArrayResId, int textViewResId) {
        return new ArrayAdapter<>(context, textViewResId, 0, Arrays.asList(context.getResources().getTextArray(textArrayResId)));
    }

    private void changedData() {
        if (notifyOnChange) notifyDataSetChanged();
    }

    public void add(T object) {
        objects.add(object);
        changedData();
    }

    public void addAll(Collection<? extends T> collection) {
        objects.addAll(collection);
        changedData();
    }

    @SuppressWarnings("unchecked")
    public void addAll(T... items) {
        Collections.addAll(objects, items);
        changedData();
    }

    public void insert(T object, int index) {
        objects.add(index, object);
        changedData();
    }

    public void remove(T object) {
        objects.remove(object);
        changedData();
    }

    public void clear() {
        objects.clear();
        changedData();
    }

    public void sort(Comparator<? super T> comparator) {
        objects.sort(comparator);
        changedData();
    }

    @Override public void notifyDataSetChanged() {
        super.notifyDataSetChanged();
        notifyOnChange = true;
    }

    public void setNotifyOnChange(boolean notifyOnChange) { this.notifyOnChange = notifyOnChange; }
    public Context getContext() { return context; }
    @Override public int getCount() { return objects.size(); }
    @Override public T getItem(int position) { return objects.get(position); }
    public int getPosition(T item) { return objects.indexOf(item); }
    @Override public long getItemId(int position) { return position; }
    @Override public View getView(int position, View convertView, ViewGroup parent) { return text(position, convertView); }
    @Override public View getDropDownView(int position, View convertView, ViewGroup parent) { return text(position, convertView); }
    public void setDropDownViewResource(int resource) {}

    private View text(int position, View convertView) {
        TextView view = convertView instanceof TextView ? (TextView) convertView : new TextView(context);
        T item = getItem(position);
        view.setText(item instanceof CharSequence ? (CharSequence) item : String.valueOf(item));
        return view;
    }
}
