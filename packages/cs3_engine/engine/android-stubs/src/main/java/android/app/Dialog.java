package android.app;

import android.content.Context;
import android.content.DialogInterface;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.KeyEvent;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import dev.akash.cs3engine.stubs.MainThread;
import dev.akash.cs3engine.stubs.Ui;
import java.util.Set;

/**
 * A stand-in dialog. Shown, its window registers with the engine (the spec's "Windows"); dismissed, it
 * leaves. Back cancels it only when it's cancelable, as on Android.
 */
public class Dialog implements DialogInterface {
    /** Android's own full-screen themes (android.R.style's …Fullscreen): a dialog made with one fills the screen. */
    private static final Set<Integer> FULL_SCREEN_THEMES = Set.of(
        16973831, // Theme_NoTitleBar_Fullscreen
        16973834, // Theme_Black_NoTitleBar_Fullscreen
        16973838, // Theme_Light_NoTitleBar_Fullscreen
        16973841, // Theme_Translucent_NoTitleBar_Fullscreen
        16973920, // Theme_Wallpaper_NoTitleBar_Fullscreen
        16973933, // Theme_Holo_NoActionBar_Fullscreen
        16974065, // Theme_Holo_Light_NoActionBar_Fullscreen
        16974122, // Theme_DeviceDefault_NoActionBar_Fullscreen
        16974125, // Theme_DeviceDefault_Light_NoActionBar_Fullscreen
        16974383, // Theme_Material_NoActionBar_Fullscreen
        16974402  // Theme_Material_Light_NoActionBar_Fullscreen
    );

    private final Context context;
    private final int theme;
    private final Window window;
    private boolean cancelable = true;
    private boolean created;
    private boolean showing;
    private boolean cancelled;
    private OnShowListener onShow;
    private OnDismissListener onDismiss;
    private OnCancelListener onCancel;
    private OnKeyListener onKey;
    private Activity ownerActivity;

    public Dialog(Context context) {
        this(context, 0);
    }

    public Dialog(Context context, int themeResId) {
        this.context = context;
        this.theme = themeResId;
        this.window = new Window(context);
    }

    protected Dialog(Context context, boolean cancelable, OnCancelListener cancelListener) {
        this(context);
        this.cancelable = cancelable;
        this.onCancel = cancelListener;
    }

    public final Context getContext() { return context; }
    public Window getWindow() { return window; }
    public LayoutInflater getLayoutInflater() { return LayoutInflater.from(context); }
    public <T extends View> T findViewById(int id) { return window.findViewById(id); }

    public final <T extends View> T requireViewById(int id) {
        T view = findViewById(id);
        if (view == null) throw new IllegalArgumentException("ID does not reference a View inside this Dialog");
        return view;
    }

    public void setContentView(View view) { window.setContentView(view); }
    public void setContentView(View view, ViewGroup.LayoutParams params) { window.setContentView(view, params); }
    public void setContentView(int layoutResID) { window.setContentView(layoutResID); }
    public void addContentView(View view, ViewGroup.LayoutParams params) { window.addContentView(view, params); }
    public void setTitle(CharSequence title) { window.setTitle(title); }
    public void setTitle(int titleId) { setTitle(context.getString(titleId)); }
    public final boolean requestWindowFeature(int featureId) { return window.requestFeature(featureId); }

    public void setCancelable(boolean flag) {
        cancelable = flag;
        Ui.changed();
    }

    public void setCanceledOnTouchOutside(boolean cancel) {
        if (cancel && !cancelable) setCancelable(true);
    }

    /** Whether Back closes it: the engine publishes it as the window's "cancelable". */
    public boolean cs3Cancelable() { return cancelable; }

    /** Whether it asks for the whole screen: a full-screen theme, or FLAG_FULLSCREEN on its window (Phase 7c's §1). */
    public boolean cs3FullScreen() {
        return FULL_SCREEN_THEMES.contains(theme) || (window.getAttributes().flags & WindowManager.LayoutParams.FLAG_FULLSCREEN) != 0;
    }

    /** Whether it asks that the screen stays on while it shows. */
    public boolean cs3KeepScreenOn() {
        return (window.getAttributes().flags & WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) != 0;
    }

    /** How the app draws its window: a plain dialog's is "dialog". */
    protected String cs3Kind() { return "dialog"; }

    public void setOnShowListener(OnShowListener listener) { onShow = listener; }
    public void setOnDismissListener(OnDismissListener listener) { onDismiss = listener; }
    public void setOnCancelListener(OnCancelListener listener) { onCancel = listener; }
    public void setOnKeyListener(OnKeyListener listener) { onKey = listener; }
    public final void setOwnerActivity(Activity activity) { ownerActivity = activity; }
    public final Activity getOwnerActivity() { return ownerActivity; }
    public boolean isShowing() { return showing; }

    public void create() {
        if (created) return;
        created = true;
        onCreate(null);
    }

    public void show() {
        if (showing) {
            window.getDecorView().setVisibility(View.VISIBLE);
            return;
        }
        create();
        onStart();
        showing = true;
        cancelled = false;
        Ui.shown(new Ui.Window(this, window.getDecorView(), cs3Kind(), Ui.fragmentOf(this)));
        // As Android's, the show listener hears after the current main-thread task.
        MainThread.post(() -> {
            if (showing && onShow != null) onShow.onShow(this);
        });
    }

    public void hide() { window.getDecorView().setVisibility(View.GONE); }

    @Override public void dismiss() {
        if (!showing) return;
        showing = false;
        onStop();
        Ui.dismissed(this);
        if (onDismiss != null) onDismiss.onDismiss(this);
    }

    @Override public void cancel() {
        if (!cancelled && onCancel != null) {
            cancelled = true;
            onCancel.onCancel(this);
        }
        dismiss();
    }

    public void onBackPressed() {
        if (cancelable) cancel();
    }

    /**
     * Back as Android's Back key reaches a dialog without predictive back (Phase 7c's §3): its key listener gets Back's
     * down and up first; only if it takes neither does the dialog get its Back. True when the listener took it.
     */
    public boolean cs3Back() {
        if (onKey != null) {
            // Timed as the device's own Back key is, the up's downTime its down's: a listener may time its double Back
            // from eventTime.
            long now = SystemClock.uptimeMillis();
            boolean down = onKey.onKey(this, KeyEvent.KEYCODE_BACK, new KeyEvent(now, now, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_BACK, 0));
            boolean up = onKey.onKey(this, KeyEvent.KEYCODE_BACK,
                new KeyEvent(now, SystemClock.uptimeMillis(), KeyEvent.ACTION_UP, KeyEvent.KEYCODE_BACK, 0));
            if (down || up) return true;
        }
        onBackPressed();
        return false;
    }

    protected void onCreate(Bundle savedInstanceState) {}
    protected void onStart() {}
    protected void onStop() {}

    public boolean onKeyDown(int keyCode, KeyEvent event) { return keyCode == KeyEvent.KEYCODE_BACK; }

    public boolean onKeyUp(int keyCode, KeyEvent event) {
        if (keyCode != KeyEvent.KEYCODE_BACK) return false;
        onBackPressed();
        return true;
    }

    public boolean dispatchKeyEvent(KeyEvent event) {
        if (onKey != null && onKey.onKey(this, event.getKeyCode(), event)) return true;
        if (window.getDecorView().dispatchKeyEvent(event)) return true;
        return event.getAction() == KeyEvent.ACTION_DOWN ? onKeyDown(event.getKeyCode(), event) : onKeyUp(event.getKeyCode(), event);
    }
}
