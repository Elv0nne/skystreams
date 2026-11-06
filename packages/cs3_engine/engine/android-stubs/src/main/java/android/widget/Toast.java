package android.widget;

import android.content.Context;
import dev.akash.cs3engine.stubs.Platform;

/** A toast: shown by the app (a snackbar), through the platform. */
public class Toast {
    public static final int LENGTH_SHORT = 0;
    public static final int LENGTH_LONG = 1;

    private final Context context;
    private CharSequence text;
    private int duration;

    public Toast(Context context) {
        this.context = context;
    }

    public static Toast makeText(Context context, CharSequence text, int duration) {
        Toast toast = new Toast(context);
        toast.text = text;
        toast.duration = duration;
        return toast;
    }

    public static Toast makeText(Context context, int resId, int duration) {
        return makeText(context, context.getString(resId), duration);
    }

    public void show() {
        if (text != null && text.length() > 0) Platform.host().toast(text);
    }

    public void cancel() {}
    public void setText(CharSequence s) { text = s; }
    public void setText(int resId) { text = context.getString(resId); }
    public void setDuration(int duration) { this.duration = duration; }
    public int getDuration() { return duration; }
}
