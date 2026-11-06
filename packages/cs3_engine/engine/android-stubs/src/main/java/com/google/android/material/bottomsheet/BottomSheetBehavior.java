package com.google.android.material.bottomsheet;

import android.content.Context;
import android.util.AttributeSet;
import android.view.View;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.WeakHashMap;
import java.util.concurrent.CopyOnWriteArrayList;

/** A bottom sheet's behaviour: its state and callbacks. A sheet's view has one; any other view doesn't, as in Material. */
public class BottomSheetBehavior<V extends View> {
    public static final int STATE_DRAGGING = 1;
    public static final int STATE_SETTLING = 2;
    public static final int STATE_EXPANDED = 3;
    public static final int STATE_COLLAPSED = 4;
    public static final int STATE_HIDDEN = 5;
    public static final int STATE_HALF_EXPANDED = 6;
    public static final int PEEK_HEIGHT_AUTO = -1;

    public abstract static class BottomSheetCallback {
        public abstract void onStateChanged(View bottomSheet, int newState);

        public abstract void onSlide(View bottomSheet, float slideOffset);
    }

    private static final Map<View, BottomSheetBehavior<?>> BEHAVIORS = Collections.synchronizedMap(new WeakHashMap<>());

    private final List<BottomSheetCallback> callbacks = new CopyOnWriteArrayList<>();
    private View sheet;
    private int state = STATE_COLLAPSED;
    private int peekHeight = PEEK_HEIGHT_AUTO;
    private boolean hideable;
    private boolean skipCollapsed;
    private boolean draggable = true;
    private boolean fitToContents = true;
    private float halfExpandedRatio = 0.5f;

    public BottomSheetBehavior() {}

    public BottomSheetBehavior(Context context, AttributeSet attrs) {}

    /** [view]'s behaviour; a view that isn't a bottom sheet throws, as Material's does. */
    @SuppressWarnings("unchecked")
    public static <V extends View> BottomSheetBehavior<V> from(V view) {
        BottomSheetBehavior<?> behavior = BEHAVIORS.get(view);
        if (behavior == null) throw new IllegalArgumentException("The view is not associated with BottomSheetBehavior");
        return (BottomSheetBehavior<V>) behavior;
    }

    static void attach(View view, BottomSheetBehavior<?> behavior) {
        behavior.sheet = view;
        BEHAVIORS.put(view, behavior);
    }

    public int getState() { return state; }

    public void setState(int state) {
        if (state == this.state) return;
        this.state = state;
        for (BottomSheetCallback callback : callbacks) callback.onStateChanged(sheet, state);
    }

    public void addBottomSheetCallback(BottomSheetCallback callback) { callbacks.add(callback); }
    public void removeBottomSheetCallback(BottomSheetCallback callback) { callbacks.remove(callback); }

    @Deprecated
    public void setBottomSheetCallback(BottomSheetCallback callback) {
        callbacks.clear();
        if (callback != null) callbacks.add(callback);
    }

    public void setPeekHeight(int peekHeight) { this.peekHeight = peekHeight; }
    public final void setPeekHeight(int peekHeight, boolean animate) { setPeekHeight(peekHeight); }
    public int getPeekHeight() { return peekHeight; }
    public void setHideable(boolean hideable) { this.hideable = hideable; }
    public boolean isHideable() { return hideable; }
    public void setSkipCollapsed(boolean skipCollapsed) { this.skipCollapsed = skipCollapsed; }
    public boolean getSkipCollapsed() { return skipCollapsed; }
    public void setDraggable(boolean draggable) { this.draggable = draggable; }
    public boolean isDraggable() { return draggable; }
    public void setFitToContents(boolean fitToContents) { this.fitToContents = fitToContents; }
    public boolean isFitToContents() { return fitToContents; }
    public void setHalfExpandedRatio(float ratio) { halfExpandedRatio = ratio; }
    public float getHalfExpandedRatio() { return halfExpandedRatio; }
}
