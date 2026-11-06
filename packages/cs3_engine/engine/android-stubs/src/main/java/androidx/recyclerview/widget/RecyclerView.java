package androidx.recyclerview.widget;

import android.content.Context;
import android.util.AttributeSet;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import dev.akash.cs3engine.stubs.Ui;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * A stand-in RecyclerView. With an adapter and a layout manager, every item (at most 500) is bound as a
 * child, in order (the spec's "Lists"). A position keeps its holder and view while its type stays the same,
 * so the person's tap lands where it was aimed.
 */
public class RecyclerView extends ViewGroup {
    public static final int HORIZONTAL = 0;
    public static final int VERTICAL = 1;
    public static final int NO_POSITION = -1;
    public static final long NO_ID = -1;
    public static final int INVALID_TYPE = -1;
    public static final int SCROLL_STATE_IDLE = 0;

    public abstract static class Adapter<VH extends ViewHolder> {
        private final List<AdapterDataObserver> observers = new CopyOnWriteArrayList<>();
        private boolean stableIds;

        public Adapter() {}

        public abstract VH onCreateViewHolder(ViewGroup parent, int viewType);
        public abstract void onBindViewHolder(VH holder, int position);
        public void onBindViewHolder(VH holder, int position, List<Object> payloads) { onBindViewHolder(holder, position); }
        public abstract int getItemCount();

        public final VH createViewHolder(ViewGroup parent, int viewType) {
            VH holder = onCreateViewHolder(parent, viewType);
            if (holder.itemView.getParent() != null) {
                throw new IllegalStateException("ViewHolder views must not be attached when created. Ensure that you are not passing 'true' to the attachToRoot parameter of LayoutInflater.inflate(..., boolean attachToRoot)");
            }
            holder.itemViewType = viewType;
            return holder;
        }

        public final void bindViewHolder(VH holder, int position) {
            holder.position = position;
            holder.bindingAdapter = this;
            if (stableIds) holder.itemId = getItemId(position);
            onBindViewHolder(holder, position, Collections.emptyList());
        }

        public int getItemViewType(int position) { return 0; }

        public void setHasStableIds(boolean hasStableIds) {
            if (hasObservers()) throw new IllegalStateException("Cannot change whether this adapter has stable IDs while the adapter has registered observers.");
            stableIds = hasStableIds;
        }

        public long getItemId(int position) { return NO_ID; }
        public final boolean hasStableIds() { return stableIds; }
        public void onViewRecycled(VH holder) {}
        public boolean onFailedToRecycleView(VH holder) { return false; }
        public void onViewAttachedToWindow(VH holder) {}
        public void onViewDetachedFromWindow(VH holder) {}
        public final boolean hasObservers() { return !observers.isEmpty(); }
        public void registerAdapterDataObserver(AdapterDataObserver observer) { observers.add(observer); }
        public void unregisterAdapterDataObserver(AdapterDataObserver observer) { observers.remove(observer); }
        public void onAttachedToRecyclerView(RecyclerView recyclerView) {}
        public void onDetachedFromRecyclerView(RecyclerView recyclerView) {}

        public final void notifyDataSetChanged() {
            for (AdapterDataObserver o : observers) o.onChanged();
        }

        public final void notifyItemChanged(int position) { notifyItemRangeChanged(position, 1); }
        public final void notifyItemChanged(int position, Object payload) { notifyItemRangeChanged(position, 1, payload); }

        public final void notifyItemRangeChanged(int positionStart, int itemCount) {
            for (AdapterDataObserver o : observers) o.onItemRangeChanged(positionStart, itemCount);
        }

        public final void notifyItemRangeChanged(int positionStart, int itemCount, Object payload) {
            for (AdapterDataObserver o : observers) o.onItemRangeChanged(positionStart, itemCount, payload);
        }

        public final void notifyItemInserted(int position) { notifyItemRangeInserted(position, 1); }

        public final void notifyItemMoved(int fromPosition, int toPosition) {
            for (AdapterDataObserver o : observers) o.onItemRangeMoved(fromPosition, toPosition, 1);
        }

        public final void notifyItemRangeInserted(int positionStart, int itemCount) {
            for (AdapterDataObserver o : observers) o.onItemRangeInserted(positionStart, itemCount);
        }

        public final void notifyItemRemoved(int position) { notifyItemRangeRemoved(position, 1); }

        public final void notifyItemRangeRemoved(int positionStart, int itemCount) {
            for (AdapterDataObserver o : observers) o.onItemRangeRemoved(positionStart, itemCount);
        }
    }

    public abstract static class AdapterDataObserver {
        public void onChanged() {}
        public void onItemRangeChanged(int positionStart, int itemCount) {}
        public void onItemRangeChanged(int positionStart, int itemCount, Object payload) { onItemRangeChanged(positionStart, itemCount); }
        public void onItemRangeInserted(int positionStart, int itemCount) {}
        public void onItemRangeRemoved(int positionStart, int itemCount) {}
        public void onItemRangeMoved(int fromPosition, int toPosition, int itemCount) {}
        public void onStateRestorationPolicyChanged() {}
    }

    public abstract static class ViewHolder {
        public final View itemView;
        int position = NO_POSITION;
        int itemViewType = INVALID_TYPE;
        long itemId = NO_ID;
        Adapter<? extends ViewHolder> bindingAdapter;
        private boolean recyclable = true;

        public ViewHolder(View itemView) {
            if (itemView == null) throw new IllegalArgumentException("itemView may not be null");
            this.itemView = itemView;
        }

        @Deprecated
        public final int getPosition() { return position; }
        public final int getLayoutPosition() { return position; }
        @Deprecated
        public final int getAdapterPosition() { return position; }
        public final int getBindingAdapterPosition() { return position; }
        public final int getAbsoluteAdapterPosition() { return position; }
        public final Adapter<? extends ViewHolder> getBindingAdapter() { return bindingAdapter; }
        public final int getOldPosition() { return NO_POSITION; }
        public final long getItemId() { return itemId; }
        public final int getItemViewType() { return itemViewType; }
        public final void setIsRecyclable(boolean recyclable) { this.recyclable = recyclable; }
        public final boolean isRecyclable() { return recyclable; }
        @Override public String toString() { return getClass().getSimpleName() + "{position=" + position + "}"; }
    }

    public abstract static class LayoutManager {
        RecyclerView recyclerView;

        public LayoutManager() {}

        public abstract LayoutParams generateDefaultLayoutParams();
        public boolean canScrollHorizontally() { return false; }
        public boolean canScrollVertically() { return false; }
        public void scrollToPosition(int position) {}
        public void setAutoMeasureEnabled(boolean enabled) {}
        public boolean isAutoMeasureEnabled() { return false; }
        public void requestLayout() {}
        public boolean isAttachedToWindow() { return recyclerView != null && recyclerView.isAttachedToWindow(); }

        public int getItemCount() {
            Adapter<?> adapter = recyclerView == null ? null : recyclerView.getAdapter();
            return adapter == null ? 0 : adapter.getItemCount();
        }

        public int getChildCount() { return recyclerView == null ? 0 : recyclerView.getChildCount(); }
        public View getChildAt(int index) { return recyclerView == null ? null : recyclerView.getChildAt(index); }

        public View findViewByPosition(int position) {
            ViewHolder holder = recyclerView == null ? null : recyclerView.findViewHolderForAdapterPosition(position);
            return holder == null ? null : holder.itemView;
        }

        public int getPosition(View view) { return recyclerView == null ? NO_POSITION : recyclerView.getChildAdapterPosition(view); }

        public void postOnAnimation(Runnable action) {
            if (recyclerView != null) recyclerView.post(action);
        }

        public boolean removeCallbacks(Runnable action) { return recyclerView != null && recyclerView.removeCallbacks(action); }
    }

    public static class LayoutParams extends ViewGroup.MarginLayoutParams {
        ViewHolder viewHolder;

        public LayoutParams(Context c, AttributeSet attrs) {
            super(c, attrs);
        }

        public LayoutParams(int width, int height) {
            super(width, height);
        }

        public LayoutParams(ViewGroup.MarginLayoutParams source) {
            super(source);
        }

        public LayoutParams(ViewGroup.LayoutParams source) {
            super(source);
        }

        public LayoutParams(LayoutParams source) {
            super((ViewGroup.MarginLayoutParams) source);
        }

        public int getViewLayoutPosition() { return viewHolder == null ? NO_POSITION : viewHolder.position; }
        public int getViewAdapterPosition() { return getViewLayoutPosition(); }
        public int getBindingAdapterPosition() { return getViewLayoutPosition(); }
        public int getAbsoluteAdapterPosition() { return getViewLayoutPosition(); }
    }

    public abstract static class ItemDecoration {}

    public abstract static class OnScrollListener {
        public void onScrollStateChanged(RecyclerView recyclerView, int newState) {}
        public void onScrolled(RecyclerView recyclerView, int dx, int dy) {}
    }

    public interface OnItemTouchListener {
        boolean onInterceptTouchEvent(RecyclerView rv, MotionEvent e);

        void onTouchEvent(RecyclerView rv, MotionEvent e);

        void onRequestDisallowInterceptTouchEvent(boolean disallowIntercept);
    }

    public interface OnChildAttachStateChangeListener {
        void onChildViewAttachedToWindow(View view);

        void onChildViewDetachedFromWindow(View view);
    }

    private Adapter<? extends ViewHolder> adapter;
    private LayoutManager layout;
    private final List<ViewHolder> holders = new ArrayList<>();

    private final AdapterDataObserver observer = new AdapterDataObserver() {
        @Override public void onChanged() { bind(); }
        @Override public void onItemRangeChanged(int positionStart, int itemCount) { bind(); }
        @Override public void onItemRangeInserted(int positionStart, int itemCount) { bind(); }
        @Override public void onItemRangeRemoved(int positionStart, int itemCount) { bind(); }
        @Override public void onItemRangeMoved(int fromPosition, int toPosition, int itemCount) { bind(); }
    };

    public RecyclerView(Context context) {
        this(context, null);
    }

    public RecyclerView(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public RecyclerView(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr, 0);
    }

    public void setAdapter(Adapter adapter) {
        if (this.adapter != null) {
            this.adapter.unregisterAdapterDataObserver(observer);
            this.adapter.onDetachedFromRecyclerView(this);
        }
        clearHolders();
        this.adapter = adapter;
        if (adapter != null) {
            adapter.registerAdapterDataObserver(observer);
            adapter.onAttachedToRecyclerView(this);
        }
        bind();
    }

    public void swapAdapter(Adapter adapter, boolean removeAndRecycleExistingViews) { setAdapter(adapter); }
    public Adapter getAdapter() { return adapter; }

    public void setLayoutManager(LayoutManager layout) {
        if (layout != null && layout.recyclerView != null && layout.recyclerView != this) {
            throw new IllegalArgumentException("LayoutManager " + layout + " is already attached to a RecyclerView: " + layout.recyclerView);
        }
        if (this.layout != null) this.layout.recyclerView = null;
        this.layout = layout;
        if (layout != null) layout.recyclerView = this;
        bind();
    }

    public LayoutManager getLayoutManager() { return layout; }

    private void clearHolders() {
        removeAllViewsInLayout();
        holders.clear();
    }

    @SuppressWarnings({"unchecked", "rawtypes"})
    private void bind() {
        if (adapter == null || layout == null) {
            clearHolders();
            changed();
            return;
        }
        Adapter raw = adapter;
        int count = Math.min(raw.getItemCount(), Ui.MAX_LIST_ITEMS);
        for (int position = 0; position < count; position++) {
            int type = raw.getItemViewType(position);
            ViewHolder holder = position < holders.size() ? holders.get(position) : null;
            if (holder == null || holder.itemViewType != type) {
                if (holder != null) removeViewInLayout(holder.itemView);
                holder = raw.createViewHolder(this, type);
                if (position < holders.size()) holders.set(position, holder);
                else holders.add(holder);
                ViewGroup.LayoutParams own = holder.itemView.getLayoutParams();
                LayoutParams params = own instanceof LayoutParams ? (LayoutParams) own
                    : own != null ? new LayoutParams(own) : layout.generateDefaultLayoutParams();
                params.viewHolder = holder;
                addViewInLayout(holder.itemView, position, params);
            }
            raw.bindViewHolder(holder, position);
        }
        while (holders.size() > count) removeViewInLayout(holders.remove(holders.size() - 1).itemView);
        changed();
    }

    public int getChildAdapterPosition(View child) {
        ViewHolder holder = holderOf(child);
        return holder == null ? NO_POSITION : holder.position;
    }

    public int getChildLayoutPosition(View child) { return getChildAdapterPosition(child); }

    public ViewHolder getChildViewHolder(View child) {
        if (child.getParent() != this) throw new IllegalArgumentException("View " + child + " is not a direct child of " + this);
        return holderOf(child);
    }

    private ViewHolder holderOf(View child) {
        for (ViewHolder holder : holders) if (holder.itemView == child) return holder;
        return null;
    }

    public ViewHolder findViewHolderForAdapterPosition(int position) { return position >= 0 && position < holders.size() ? holders.get(position) : null; }
    public ViewHolder findViewHolderForLayoutPosition(int position) { return findViewHolderForAdapterPosition(position); }

    public View findContainingItemView(View view) {
        View current = view;
        while (current != null && current.getParent() != this) current = current.getParent() instanceof View ? (View) current.getParent() : null;
        return current;
    }

    public ViewHolder findContainingViewHolder(View view) {
        View item = findContainingItemView(view);
        return item == null ? null : holderOf(item);
    }

    public void addItemDecoration(ItemDecoration decor) {}
    public void removeItemDecoration(ItemDecoration decor) {}
    public void addOnScrollListener(OnScrollListener listener) {}
    public void removeOnScrollListener(OnScrollListener listener) {}
    public void clearOnScrollListeners() {}
    public void addOnItemTouchListener(OnItemTouchListener listener) {}
    public void removeOnItemTouchListener(OnItemTouchListener listener) {}
    public void addOnChildAttachStateChangeListener(OnChildAttachStateChangeListener listener) {}
    public void removeOnChildAttachStateChangeListener(OnChildAttachStateChangeListener listener) {}
    public void scrollToPosition(int position) {}
    public void smoothScrollToPosition(int position) {}
    public void setHasFixedSize(boolean hasFixedSize) {}
    public void setItemViewCacheSize(int size) {}
    @Override protected void onLayout(boolean changed, int l, int t, int r, int b) {}

    @Override protected ViewGroup.LayoutParams generateDefaultLayoutParams() {
        return layout != null ? layout.generateDefaultLayoutParams() : new LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT);
    }

    @Override public ViewGroup.LayoutParams generateLayoutParams(AttributeSet attrs) { return new LayoutParams(getContext(), attrs); }

    @Override protected ViewGroup.LayoutParams generateLayoutParams(ViewGroup.LayoutParams p) {
        return p instanceof ViewGroup.MarginLayoutParams ? new LayoutParams((ViewGroup.MarginLayoutParams) p) : new LayoutParams(p);
    }

    @Override protected boolean checkLayoutParams(ViewGroup.LayoutParams p) { return p instanceof LayoutParams; }
}
