package android.view;

import android.content.Context;
import android.content.res.Resources;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.Drawable;
import android.os.Handler;
import android.util.AttributeSet;
import dev.akash.cs3engine.stubs.LayoutAttributes;
import dev.akash.cs3engine.stubs.Ui;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * A stand-in view (the spec's part 2): it keeps its state and calls its listeners; nothing is measured or
 * drawn, so every size is 0. Setters the screen's tree reads mark it changed, for the engine to read it again.
 */
public class View {
    public static final int NO_ID = -1;
    public static final int VISIBLE = 0x00000000;
    public static final int INVISIBLE = 0x00000004;
    public static final int GONE = 0x00000008;
    public static final int IMPORTANT_FOR_ACCESSIBILITY_AUTO = 0x00000000;
    public static final int IMPORTANT_FOR_ACCESSIBILITY_YES = 0x00000001;
    public static final int IMPORTANT_FOR_ACCESSIBILITY_NO = 0x00000002;
    public static final int IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS = 0x00000004;

    public interface OnClickListener {
        void onClick(View v);
    }

    public interface OnLongClickListener {
        boolean onLongClick(View v);
    }

    public interface OnFocusChangeListener {
        void onFocusChange(View v, boolean hasFocus);
    }

    public interface OnKeyListener {
        boolean onKey(View v, int keyCode, KeyEvent event);
    }

    public interface OnTouchListener {
        boolean onTouch(View v, MotionEvent event);
    }

    public interface OnAttachStateChangeListener {
        void onViewAttachedToWindow(View v);

        void onViewDetachedFromWindow(View v);
    }

    public interface OnLayoutChangeListener {
        void onLayoutChange(View v, int left, int top, int right, int bottom, int oldLeft, int oldTop, int oldRight, int oldBottom);
    }

    private static final AtomicInteger NEXT_ID = new AtomicInteger(1);
    private static final Handler HANDLER = new Handler();

    private final Context context;
    ViewParent parent;
    private int id = NO_ID;
    private int visibility = VISIBLE;
    private boolean enabled = true;
    private boolean clickable;
    private boolean longClickable;
    private boolean focusable;
    private boolean focusableInTouchMode;
    private boolean selected;
    private boolean activated;
    private boolean pressed;
    private CharSequence contentDescription;
    private Object tag;
    private Map<Integer, Object> keyedTags;
    private ViewGroup.LayoutParams layoutParams;
    private OnClickListener onClick;
    private OnLongClickListener onLongClick;
    private OnFocusChangeListener onFocusChange;
    private OnKeyListener onKey;
    private OnTouchListener onTouch;
    private final List<OnAttachStateChangeListener> attachListeners = new ArrayList<>();
    private float alpha = 1f;
    private float translationX;
    private float translationY;
    private float scaleX = 1f;
    private float scaleY = 1f;
    private float rotation;
    private float elevation;
    private int paddingLeft;
    private int paddingTop;
    private int paddingRight;
    private int paddingBottom;
    private int minimumWidth;
    private int minimumHeight;
    private int importantForAccessibility;
    private Drawable background;
    private ViewTreeObserver observer;
    private ViewPropertyAnimator animator;

    public View(Context context) {
        this.context = context;
    }

    public View(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public View(Context context, AttributeSet attrs, int defStyleAttr) {
        this(context, attrs, defStyleAttr, 0);
    }

    /** A layout's view: its attributes are set here, as Android's constructors set them (LayoutAttributes). */
    public View(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        this(context);
        LayoutAttributes.view(this, attrs);
    }

    /** The screen's tree changed: the engine reads it again. */
    protected void changed() {
        Ui.changed();
    }

    public Context getContext() { return context; }
    public Resources getResources() { return context != null ? context.getResources() : Resources.getSystem(); }
    public int getId() { return id; }
    public void setId(int id) { this.id = id; }
    public static int generateViewId() { return NEXT_ID.getAndIncrement(); }

    public static View inflate(Context context, int resource, ViewGroup root) {
        return LayoutInflater.from(context).inflate(resource, root);
    }

    public int getVisibility() { return visibility; }

    public void setVisibility(int visibility) {
        if (this.visibility == visibility) return;
        this.visibility = visibility;
        changed();
    }

    /** Visible all the way up, in a showing window. */
    public boolean isShown() {
        View view = this;
        while (true) {
            if (view.visibility != VISIBLE) return false;
            if (!(view.parent instanceof View)) return Ui.isShowing(view);
            view = (View) view.parent;
        }
    }

    public boolean isAttachedToWindow() { return Ui.isShowing(getRootView()); }
    public boolean isEnabled() { return enabled; }

    public void setEnabled(boolean enabled) {
        if (this.enabled == enabled) return;
        this.enabled = enabled;
        changed();
    }

    public boolean isClickable() { return clickable; }
    public void setClickable(boolean clickable) { this.clickable = clickable; }
    public boolean isLongClickable() { return longClickable; }
    public void setLongClickable(boolean longClickable) { this.longClickable = longClickable; }
    public boolean isFocusable() { return focusable; }
    public void setFocusable(boolean focusable) { this.focusable = focusable; }
    public boolean isFocusableInTouchMode() { return focusableInTouchMode; }
    public void setFocusableInTouchMode(boolean focusableInTouchMode) { this.focusableInTouchMode = focusableInTouchMode; }
    public boolean requestFocus() { return false; }
    public final boolean requestFocus(int direction) { return requestFocus(); }
    public void clearFocus() {}
    public boolean hasFocus() { return false; }
    public boolean isFocused() { return false; }
    public boolean isSelected() { return selected; }
    public void setSelected(boolean selected) { this.selected = selected; }
    public boolean isActivated() { return activated; }
    public void setActivated(boolean activated) { this.activated = activated; }
    public boolean isPressed() { return pressed; }
    public void setPressed(boolean pressed) { this.pressed = pressed; }
    public CharSequence getContentDescription() { return contentDescription; }

    public void setContentDescription(CharSequence contentDescription) {
        this.contentDescription = contentDescription;
        changed();
    }

    public Object getTag() { return tag; }
    public void setTag(Object tag) { this.tag = tag; }
    public Object getTag(int key) { return keyedTags == null ? null : keyedTags.get(key); }

    public void setTag(int key, Object tag) {
        if (keyedTags == null) keyedTags = new HashMap<>();
        keyedTags.put(key, tag);
    }

    public final ViewParent getParent() { return parent; }

    public View getRootView() {
        View view = this;
        while (view.parent instanceof View) view = (View) view.parent;
        return view;
    }

    @SuppressWarnings("unchecked")
    public final <T extends View> T findViewById(int id) {
        return id == NO_ID ? null : (T) findViewTraversal(id);
    }

    /** This view, if it has [id]; a group looks through its children too. */
    protected View findViewTraversal(int id) {
        return id == this.id ? this : null;
    }

    public final <T extends View> T requireViewById(int id) {
        T view = findViewById(id);
        if (view == null) throw new IllegalArgumentException("ID does not reference a View inside this View");
        return view;
    }

    @SuppressWarnings("unchecked")
    public final <T extends View> T findViewWithTag(Object tag) {
        return tag == null ? null : (T) findViewWithTagTraversal(tag);
    }

    protected View findViewWithTagTraversal(Object tag) {
        return tag.equals(this.tag) ? this : null;
    }

    public void setOnClickListener(OnClickListener listener) {
        if (!clickable) setClickable(true);
        onClick = listener;
        changed();
    }

    public boolean hasOnClickListeners() { return onClick != null; }

    public boolean performClick() {
        if (onClick == null) return false;
        onClick.onClick(this);
        return true;
    }

    public boolean callOnClick() { return performClick(); }

    public void setOnLongClickListener(OnLongClickListener listener) {
        if (!longClickable) setLongClickable(true);
        onLongClick = listener;
    }

    public boolean performLongClick() { return onLongClick != null && onLongClick.onLongClick(this); }
    public void setOnFocusChangeListener(OnFocusChangeListener listener) { onFocusChange = listener; }
    public OnFocusChangeListener getOnFocusChangeListener() { return onFocusChange; }
    public void setOnKeyListener(OnKeyListener listener) { onKey = listener; }
    public void setOnTouchListener(OnTouchListener listener) { onTouch = listener; }

    public boolean dispatchTouchEvent(MotionEvent event) {
        if (onTouch != null && enabled && onTouch.onTouch(this, event)) return true;
        return onTouchEvent(event);
    }

    /** Taps come to the stand-ins as actions, never as touches. */
    public boolean onTouchEvent(MotionEvent event) { return false; }

    public boolean dispatchKeyEvent(KeyEvent event) {
        if (onKey != null && enabled && onKey.onKey(this, event.getKeyCode(), event)) return true;
        return event.getAction() == KeyEvent.ACTION_DOWN ? onKeyDown(event.getKeyCode(), event) : onKeyUp(event.getKeyCode(), event);
    }

    public boolean onKeyDown(int keyCode, KeyEvent event) { return false; }
    public boolean onKeyUp(int keyCode, KeyEvent event) { return false; }
    public ViewGroup.LayoutParams getLayoutParams() { return layoutParams; }

    public void setLayoutParams(ViewGroup.LayoutParams params) {
        if (params == null) throw new NullPointerException("Layout parameters cannot be null");
        layoutParams = params;
        changed();
    }

    public final int getWidth() { return 0; }
    public final int getHeight() { return 0; }
    public final int getMeasuredWidth() { return 0; }
    public final int getMeasuredHeight() { return 0; }
    public final int getLeft() { return 0; }
    public final int getTop() { return 0; }
    public final int getRight() { return 0; }
    public final int getBottom() { return 0; }
    public float getX() { return translationX; }
    public float getY() { return translationY; }

    public void setPadding(int left, int top, int right, int bottom) {
        paddingLeft = left;
        paddingTop = top;
        paddingRight = right;
        paddingBottom = bottom;
    }

    public void setPaddingRelative(int start, int top, int end, int bottom) { setPadding(start, top, end, bottom); }
    public int getPaddingLeft() { return paddingLeft; }
    public int getPaddingTop() { return paddingTop; }
    public int getPaddingRight() { return paddingRight; }
    public int getPaddingBottom() { return paddingBottom; }
    public int getPaddingStart() { return paddingLeft; }
    public int getPaddingEnd() { return paddingRight; }
    public float getAlpha() { return alpha; }
    public void setAlpha(float alpha) { this.alpha = alpha; }
    public float getTranslationX() { return translationX; }
    public void setTranslationX(float translationX) { this.translationX = translationX; }
    public float getTranslationY() { return translationY; }
    public void setTranslationY(float translationY) { this.translationY = translationY; }
    public float getScaleX() { return scaleX; }
    public void setScaleX(float scaleX) { this.scaleX = scaleX; }
    public float getScaleY() { return scaleY; }
    public void setScaleY(float scaleY) { this.scaleY = scaleY; }
    public float getRotation() { return rotation; }
    public void setRotation(float rotation) { this.rotation = rotation; }
    public float getElevation() { return elevation; }
    public void setElevation(float elevation) { this.elevation = elevation; }
    public int getMinimumWidth() { return minimumWidth; }
    public void setMinimumWidth(int minWidth) { minimumWidth = minWidth; }
    public int getMinimumHeight() { return minimumHeight; }
    public void setMinimumHeight(int minHeight) { minimumHeight = minHeight; }
    public int getImportantForAccessibility() { return importantForAccessibility; }
    public void setImportantForAccessibility(int mode) { importantForAccessibility = mode; }
    public Drawable getBackground() { return background; }
    public void setBackground(Drawable background) { this.background = background; }

    @Deprecated
    public void setBackgroundDrawable(Drawable background) { setBackground(background); }

    public void setBackgroundColor(int color) { setBackground(new ColorDrawable(color)); }
    public void setBackgroundResource(int resid) {}

    public ViewTreeObserver getViewTreeObserver() {
        if (observer == null) observer = new ViewTreeObserver();
        return observer;
    }

    public ViewPropertyAnimator animate() {
        if (animator == null) animator = new ViewPropertyAnimator(this);
        return animator;
    }

    public Handler getHandler() { return HANDLER; }

    // Through the main thread's handler, as Android's views post, so removeCallbacks takes a post back.
    public boolean post(Runnable action) { return HANDLER.post(action); }
    public boolean postDelayed(Runnable action, long delayMillis) { return HANDLER.postDelayed(action, delayMillis); }
    public void postOnAnimation(Runnable action) { post(action); }
    public void postOnAnimationDelayed(Runnable action, long delayMillis) { postDelayed(action, delayMillis); }

    public boolean removeCallbacks(Runnable action) {
        HANDLER.removeCallbacks(action);
        return true;
    }
    public void addOnAttachStateChangeListener(OnAttachStateChangeListener listener) { attachListeners.add(listener); }
    public void removeOnAttachStateChangeListener(OnAttachStateChangeListener listener) { attachListeners.remove(listener); }
    public void addOnLayoutChangeListener(OnLayoutChangeListener listener) {}
    public void removeOnLayoutChangeListener(OnLayoutChangeListener listener) {}
    public void invalidate() {}
    public void requestLayout() {}
    public void forceLayout() {}
    public boolean isLayoutRequested() { return false; }
    public boolean isLaidOut() { return false; }
    public boolean isInEditMode() { return false; }
    public void bringToFront() {}

    @Override public String toString() {
        return getClass().getName() + "{" + Integer.toHexString(System.identityHashCode(this)) + (id != NO_ID ? " #" + Integer.toHexString(id) : "") + "}";
    }
}
