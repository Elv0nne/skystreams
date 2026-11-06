package androidx.appcompat.app;

import android.content.Context;
import androidx.activity.ComponentDialog;

/** AppCompat's dialog: a ComponentDialog that can turn its title off. */
public class AppCompatDialog extends ComponentDialog {
    public AppCompatDialog(Context context) {
        this(context, 0);
    }

    public AppCompatDialog(Context context, int theme) {
        super(context, theme);
    }

    protected AppCompatDialog(Context context, boolean cancelable, OnCancelListener cancelListener) {
        super(context);
        setCancelable(cancelable);
        setOnCancelListener(cancelListener);
    }

    public boolean supportRequestWindowFeature(int featureId) { return getWindow().requestFeature(featureId); }
}
