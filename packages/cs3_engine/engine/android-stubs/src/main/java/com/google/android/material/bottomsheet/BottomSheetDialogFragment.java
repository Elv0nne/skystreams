package com.google.android.material.bottomsheet;

import android.app.Dialog;
import android.os.Bundle;
import androidx.appcompat.app.AppCompatDialogFragment;

/** Material's bottom-sheet fragment: its dialog is a BottomSheetDialog. Dismissing it skips the slide away. */
public class BottomSheetDialogFragment extends AppCompatDialogFragment {
    public BottomSheetDialogFragment() {}

    public BottomSheetDialogFragment(int contentLayoutId) {
        super(contentLayoutId);
    }

    @Override public Dialog onCreateDialog(Bundle savedInstanceState) {
        return new BottomSheetDialog(getContext(), getTheme());
    }
}
