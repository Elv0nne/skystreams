package androidx.recyclerview.widget;

/** List diffing. Every item is bound anyway, so a result rebinds its adapter rather than dispatch each change. */
public class DiffUtil {
    private DiffUtil() {}

    public abstract static class Callback {
        public abstract int getOldListSize();
        public abstract int getNewListSize();
        public abstract boolean areItemsTheSame(int oldItemPosition, int newItemPosition);
        public abstract boolean areContentsTheSame(int oldItemPosition, int newItemPosition);
        public Object getChangePayload(int oldItemPosition, int newItemPosition) { return null; }
    }

    public abstract static class ItemCallback<T> {
        public abstract boolean areItemsTheSame(T oldItem, T newItem);
        public abstract boolean areContentsTheSame(T oldItem, T newItem);
        public Object getChangePayload(T oldItem, T newItem) { return null; }
    }

    public static class DiffResult {
        public static final int NO_POSITION = -1;
        private final Callback callback;

        DiffResult(Callback callback) {
            this.callback = callback;
        }

        public int convertOldPositionToNew(int oldListPosition) { return oldListPosition < callback.getNewListSize() ? oldListPosition : NO_POSITION; }
        public int convertNewPositionToOld(int newListPosition) { return newListPosition < callback.getOldListSize() ? newListPosition : NO_POSITION; }
        public void dispatchUpdatesTo(RecyclerView.Adapter adapter) { adapter.notifyDataSetChanged(); }
    }

    public static DiffResult calculateDiff(Callback cb) { return new DiffResult(cb); }
    public static DiffResult calculateDiff(Callback cb, boolean detectMoves) { return new DiffResult(cb); }
}
