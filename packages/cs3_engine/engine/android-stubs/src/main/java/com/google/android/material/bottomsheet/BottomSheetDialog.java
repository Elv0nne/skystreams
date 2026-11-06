package com.google.android.material.bottomsheet;

import android.content.Context;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.widget.FrameLayout;
import androidx.appcompat.app.AppCompatDialog;
import com.google.android.material.R;

/**
 * Material's bottom sheet: its content sits in a frame with R.id.design_bottom_sheet, whose behaviour holds its
 * state (hidden, it cancels). It shows no title, as Material's doesn't.
 */
public class BottomSheetDialog extends AppCompatDialog {
    private final FrameLayout sheet;
    private final BottomSheetBehavior<FrameLayout> behavior = new BottomSheetBehavior<>();

    public BottomSheetDialog(Context context) {
        this(context, 0);
    }

    public BottomSheetDialog(Context context, int theme) {
        super(context, theme);
        supportRequestWindowFeature(Window.FEATURE_NO_TITLE);
        sheet = new FrameLayout(context);
        sheet.setId(R.id.design_bottom_sheet);
        BottomSheetBehavior.attach(sheet, behavior);
        behavior.addBottomSheetCallback(new BottomSheetBehavior.BottomSheetCallback() {
            @Override public void onStateChanged(View bottomSheet, int newState) {
                if (newState == BottomSheetBehavior.STATE_HIDDEN) cancel();
            }

            @Override public void onSlide(View bottomSheet, float slideOffset) {}
        });
        super.setContentView(sheet);
    }

    protected BottomSheetDialog(Context context, boolean cancelable, OnCancelListener cancelListener) {
        this(context, 0);
        setCancelable(cancelable);
        setOnCancelListener(cancelListener);
    }

    @Override public void setContentView(View view) {
        sheet.removeAllViews();
        sheet.addView(view);
    }

    @Override public void setContentView(View view, ViewGroup.LayoutParams params) {
        sheet.removeAllViews();
        sheet.addView(view, params);
    }

    @Override public void setContentView(int layoutResId) { setContentView(getLayoutInflater().inflate(layoutResId, sheet, false)); }
    @Override protected String cs3Kind() { return "sheet"; }
    public BottomSheetBehavior<FrameLayout> getBehavior() { return behavior; }
    public void setDismissWithAnimation(boolean dismissWithAnimation) {}
    public boolean getDismissWithAnimation() { return false; }
}
