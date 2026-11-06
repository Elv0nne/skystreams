package androidx.recyclerview.widget;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * A RecyclerView adapter over a list. Android diffs a new list off the main thread and dispatches the
 * changes; every item is bound anyway, so a new list rebinds at once and its callback runs.
 */
public abstract class ListAdapter<T, VH extends RecyclerView.ViewHolder> extends RecyclerView.Adapter<VH> {
    private List<T> current = Collections.emptyList();

    protected ListAdapter(DiffUtil.ItemCallback<T> diffCallback) {}

    public void submitList(List<T> list) { submitList(list, null); }

    public void submitList(List<T> list, Runnable commitCallback) {
        List<T> previous = current;
        current = list == null ? Collections.emptyList() : Collections.unmodifiableList(new ArrayList<>(list));
        notifyDataSetChanged();
        onCurrentListChanged(previous, current);
        if (commitCallback != null) commitCallback.run();
    }

    protected T getItem(int position) { return current.get(position); }
    @Override public int getItemCount() { return current.size(); }
    public List<T> getCurrentList() { return current; }
    public void onCurrentListChanged(List<T> previousList, List<T> currentList) {}
}
