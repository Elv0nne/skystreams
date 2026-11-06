package android.view;

import android.content.Context;
import android.graphics.drawable.Drawable;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import dev.akash.cs3engine.stubs.Ui;

/**
 * A stand-in window: a decor column holding a content frame (android.R.id.content), and a title line above it
 * when a title is set and the title feature isn't off. It keeps the parameters extensions set.
 */
public class Window {
    public static final int FEATURE_NO_TITLE = 1;

    private final Context context;
    private final WindowManager.LayoutParams attributes = new WindowManager.LayoutParams();
    private final LinearLayout decor;
    private final FrameLayout content;
    private TextView titleView;
    private boolean noTitle;

    public Window(Context context) {
        this.context = context;
        decor = new LinearLayout(context);
        decor.setOrientation(LinearLayout.VERTICAL);
        content = new FrameLayout(context);
        content.setId(android.R.id.content);
        decor.addView(content);
    }

    public final Context getContext() { return context; }
    public View getDecorView() { return decor; }
    public View peekDecorView() { return decor; }
    public <T extends View> T findViewById(int id) { return decor.findViewById(id); }

    public void setContentView(View view) {
        content.removeAllViews();
        content.addView(view);
    }

    public void setContentView(View view, ViewGroup.LayoutParams params) {
        content.removeAllViews();
        content.addView(view, params);
    }

    /** One of the app's layouts: extensions' aren't the app's, so this fails for them, as on Android. */
    public void setContentView(int layoutResID) { setContentView(getLayoutInflater().inflate(layoutResID, content, false)); }
    public void addContentView(View view, ViewGroup.LayoutParams params) { content.addView(view, params); }
    public LayoutInflater getLayoutInflater() { return LayoutInflater.from(context); }

    public boolean requestFeature(int featureId) {
        if (featureId == FEATURE_NO_TITLE) {
            noTitle = true;
            setTitle(null);
        }
        return true;
    }

    /** A title line above the content (20sp, as Android's dialog titles), unless the title feature is off. */
    public void setTitle(CharSequence title) {
        if (noTitle || title == null || title.length() == 0) {
            if (titleView != null) decor.removeView(titleView);
            titleView = null;
            return;
        }
        if (titleView == null) {
            titleView = new TextView(context);
            titleView.setTextSize(20f);
            decor.addView(titleView, 0);
        }
        titleView.setText(title);
    }

    public final WindowManager.LayoutParams getAttributes() { return attributes; }

    public void setAttributes(WindowManager.LayoutParams a) {
        if (a == attributes) return;
        attributes.width = a.width;
        attributes.height = a.height;
        attributes.flags = a.flags;
        attributes.gravity = a.gravity;
        attributes.x = a.x;
        attributes.y = a.y;
        attributes.alpha = a.alpha;
        attributes.dimAmount = a.dimAmount;
        attributes.softInputMode = a.softInputMode;
        attributes.windowAnimations = a.windowAnimations;
    }

    public void setLayout(int width, int height) {
        attributes.width = width;
        attributes.height = height;
    }

    public void setGravity(int gravity) { attributes.gravity = gravity; }

    /** Flags an extension sets on a shown window are read again (Phase 7c's §1: a reader asking for the whole screen). */
    public void setFlags(int flags, int mask) {
        attributes.flags = (attributes.flags & ~mask) | (flags & mask);
        Ui.changed();
    }

    public void addFlags(int flags) { setFlags(flags, flags); }
    public void clearFlags(int flags) { setFlags(0, flags); }
    public void setDimAmount(float amount) { attributes.dimAmount = amount; }
    public void setSoftInputMode(int mode) { attributes.softInputMode = mode; }
    public void setWindowAnimations(int resId) { attributes.windowAnimations = resId; }
    public void setBackgroundDrawable(Drawable drawable) {}
    public void setBackgroundDrawableResource(int resId) {}
    public void setStatusBarColor(int color) {}
    public int getStatusBarColor() { return 0; }
    public void setNavigationBarColor(int color) {}
    public int getNavigationBarColor() { return 0; }
    public View getCurrentFocus() { return null; }
    public boolean isFloating() { return true; }
}
