package com.google.android.material.dialog;

import android.content.Context;
import android.graphics.drawable.Drawable;
import androidx.appcompat.app.AlertDialog;

/**
 * Material's alert builder: AppCompat's. Material narrows each setter's return type; framework-gen adds those
 * as calls to AppCompat's, so the title and buttons are kept (the spec's "never covers behaviour").
 */
public class MaterialAlertDialogBuilder extends AlertDialog.Builder {
    public MaterialAlertDialogBuilder(Context context) {
        super(context);
    }

    public MaterialAlertDialogBuilder(Context context, int overrideThemeResId) {
        super(context, overrideThemeResId);
    }

    public Drawable getBackground() { return null; }
    public MaterialAlertDialogBuilder setBackground(Drawable background) { return this; }
}
