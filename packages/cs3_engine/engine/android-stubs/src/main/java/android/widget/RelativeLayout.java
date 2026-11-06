package android.widget;

import android.content.Context;
import android.util.AttributeSet;
import android.view.ViewGroup;
import java.util.HashMap;
import java.util.Map;

/** A stand-in relative layout: its children in order, their rules kept (nothing is placed). */
public class RelativeLayout extends ViewGroup {
    public static final int TRUE = -1;

    public static class LayoutParams extends ViewGroup.MarginLayoutParams {
        private final Map<Integer, Integer> rules = new HashMap<>();

        public LayoutParams(Context c, AttributeSet attrs) {
            super(c, attrs);
        }

        public LayoutParams(int w, int h) {
            super(w, h);
        }

        public LayoutParams(ViewGroup.LayoutParams source) {
            super(source);
        }

        public LayoutParams(ViewGroup.MarginLayoutParams source) {
            super(source);
        }

        public LayoutParams(LayoutParams source) {
            super(source);
            rules.putAll(source.rules);
        }

        public void addRule(int verb) { rules.put(verb, TRUE); }
        public void addRule(int verb, int subject) { rules.put(verb, subject); }
        public void removeRule(int verb) { rules.remove(verb); }
        public int getRule(int verb) { return rules.getOrDefault(verb, 0); }
    }

    public RelativeLayout(Context context) {
        this(context, null);
    }

    public RelativeLayout(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public RelativeLayout(Context context, AttributeSet attrs, int defStyleAttr) {
        this(context, attrs, defStyleAttr, 0);
    }

    public RelativeLayout(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
    }

    @Override protected LayoutParams generateDefaultLayoutParams() {
        return new LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT);
    }

    @Override public LayoutParams generateLayoutParams(AttributeSet attrs) { return new LayoutParams(getContext(), attrs); }

    @Override protected ViewGroup.LayoutParams generateLayoutParams(ViewGroup.LayoutParams p) {
        if (p instanceof LayoutParams) return new LayoutParams((LayoutParams) p);
        if (p instanceof ViewGroup.MarginLayoutParams) return new LayoutParams((ViewGroup.MarginLayoutParams) p);
        return new LayoutParams(p);
    }

    @Override protected boolean checkLayoutParams(ViewGroup.LayoutParams p) { return p instanceof LayoutParams; }
    @Override protected void onLayout(boolean changed, int l, int t, int r, int b) {}
}
