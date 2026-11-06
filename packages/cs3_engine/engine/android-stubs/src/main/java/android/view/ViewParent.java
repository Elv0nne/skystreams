package android.view;

/** What holds a view. framework-gen adds the rest of Android's methods; ViewGroup's fill implements them. */
public interface ViewParent {
    ViewParent getParent();
    void requestLayout();
    void requestDisallowInterceptTouchEvent(boolean disallowIntercept);
    void bringChildToFront(View child);
}
