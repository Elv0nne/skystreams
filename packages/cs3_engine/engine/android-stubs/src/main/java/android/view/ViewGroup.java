package android.view;

import android.content.Context;
import android.util.AttributeSet;
import dev.akash.cs3engine.stubs.Axml;
import java.util.ArrayList;
import java.util.List;

/** A stand-in group: its children in order. Abstract, as Android's: subclasses lay nothing out. */
public abstract class ViewGroup extends View implements ViewParent, ViewManager {
    public static final int FOCUS_BEFORE_DESCENDANTS = 0x20000;
    public static final int FOCUS_AFTER_DESCENDANTS = 0x40000;
    public static final int FOCUS_BLOCK_DESCENDANTS = 0x60000;

    public static class LayoutParams {
        @Deprecated
        public static final int FILL_PARENT = -1;
        public static final int MATCH_PARENT = -1;
        public static final int WRAP_CONTENT = -2;

        public int width;
        public int height;

        /** As a layout says: its layout_width and layout_height (other attributes are its subclasses'). */
        public LayoutParams(Context c, AttributeSet attrs) {
            this(Axml.layoutSize(attrs, "layout_width"), Axml.layoutSize(attrs, "layout_height"));
        }

        public LayoutParams(int width, int height) {
            this.width = width;
            this.height = height;
        }

        public LayoutParams(LayoutParams source) {
            this(source.width, source.height);
        }
    }

    public static class MarginLayoutParams extends LayoutParams {
        public int leftMargin;
        public int topMargin;
        public int rightMargin;
        public int bottomMargin;

        public MarginLayoutParams(Context c, AttributeSet attrs) {
            super(c, attrs);
        }

        public MarginLayoutParams(int width, int height) {
            super(width, height);
        }

        public MarginLayoutParams(MarginLayoutParams source) {
            super(source);
            setMargins(source.leftMargin, source.topMargin, source.rightMargin, source.bottomMargin);
        }

        public MarginLayoutParams(LayoutParams source) {
            super(source);
        }

        public void setMargins(int left, int top, int right, int bottom) {
            leftMargin = left;
            topMargin = top;
            rightMargin = right;
            bottomMargin = bottom;
        }

        public void setMarginStart(int start) { leftMargin = start; }
        public void setMarginEnd(int end) { rightMargin = end; }
        public int getMarginStart() { return leftMargin; }
        public int getMarginEnd() { return rightMargin; }
    }

    private final List<View> children = new ArrayList<>();
    private int descendantFocusability = FOCUS_BEFORE_DESCENDANTS;

    public ViewGroup(Context context) {
        super(context);
    }

    public ViewGroup(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    public ViewGroup(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
    }

    public ViewGroup(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
    }

    protected abstract void onLayout(boolean changed, int l, int t, int r, int b);

    public int getChildCount() { return children.size(); }
    public View getChildAt(int index) { return index >= 0 && index < children.size() ? children.get(index) : null; }
    public int indexOfChild(View child) { return children.indexOf(child); }
    public void addView(View child) { addView(child, -1); }

    public void addView(View child, int index) {
        if (child == null) throw new IllegalArgumentException("Cannot add a null child view to a ViewGroup");
        LayoutParams params = child.getLayoutParams();
        addView(child, index, params != null ? params : generateDefaultLayoutParams());
    }

    public void addView(View child, int width, int height) {
        LayoutParams params = generateDefaultLayoutParams();
        params.width = width;
        params.height = height;
        addView(child, -1, params);
    }

    @Override public void addView(View child, LayoutParams params) { addView(child, -1, params); }

    public void addView(View child, int index, LayoutParams params) { attach(child, index, params); }

    /** As addView, for a group's own children: adapter views refuse addView, as Android's do, and bind this way. */
    protected boolean addViewInLayout(View child, int index, LayoutParams params) {
        attach(child, index, params);
        return true;
    }

    private void attach(View child, int index, LayoutParams params) {
        if (child == null) throw new IllegalArgumentException("Cannot add a null child view to a ViewGroup");
        if (child.parent != null) {
            throw new IllegalStateException("The specified child already has a parent. You must call removeView() on the child's parent first.");
        }
        if (!checkLayoutParams(params)) params = generateLayoutParams(params);
        child.setLayoutParams(params);
        child.parent = this;
        if (index < 0 || index > children.size()) children.add(child);
        else children.add(index, child);
        onViewAdded(child);
        changed();
    }

    @Override public void updateViewLayout(View view, LayoutParams params) { view.setLayoutParams(params); }

    @Override public void removeView(View view) { removeViewInLayout(view); }
    public void removeViewAt(int index) { detach(index); }

    public void removeViews(int start, int count) {
        for (int i = 0; i < count; i++) detach(start);
    }

    public void removeViewInLayout(View view) {
        int index = children.indexOf(view);
        if (index >= 0) detach(index);
    }

    public void removeAllViews() { removeAllViewsInLayout(); }

    public void removeAllViewsInLayout() {
        while (!children.isEmpty()) detach(children.size() - 1);
    }

    private void detach(int index) {
        View child = children.remove(index);
        child.parent = null;
        onViewRemoved(child);
        changed();
    }
    public void onViewAdded(View child) {}
    public void onViewRemoved(View child) {}
    protected LayoutParams generateDefaultLayoutParams() { return new LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT); }
    public LayoutParams generateLayoutParams(AttributeSet attrs) { return new LayoutParams(getContext(), attrs); }
    protected LayoutParams generateLayoutParams(LayoutParams p) { return p; }
    protected boolean checkLayoutParams(LayoutParams p) { return p != null; }

    @Override protected View findViewTraversal(int id) {
        if (id == getId()) return this;
        for (View child : children) {
            View found = child.findViewById(id);
            if (found != null) return found;
        }
        return null;
    }

    @Override protected View findViewWithTagTraversal(Object tag) {
        if (tag.equals(getTag())) return this;
        for (View child : children) {
            View found = child.findViewWithTag(tag);
            if (found != null) return found;
        }
        return null;
    }

    @Override public void requestDisallowInterceptTouchEvent(boolean disallowIntercept) {}
    public boolean onInterceptTouchEvent(MotionEvent ev) { return false; }
    public int getDescendantFocusability() { return descendantFocusability; }
    public void setDescendantFocusability(int focusability) { descendantFocusability = focusability; }

    @Override public void bringChildToFront(View child) {
        if (children.remove(child)) {
            children.add(child);
            changed();
        }
    }

    public boolean shouldDelayChildPressedState() { return true; }
}
