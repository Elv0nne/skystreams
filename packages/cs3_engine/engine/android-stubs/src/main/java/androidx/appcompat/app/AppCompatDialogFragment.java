package androidx.appcompat.app;

import android.app.Dialog;
import android.os.Bundle;
import android.view.Window;
import android.view.WindowManager;
import androidx.fragment.app.DialogFragment;

/** AppCompat's dialog fragment: its dialog is an AppCompatDialog. */
public class AppCompatDialogFragment extends DialogFragment {
    public AppCompatDialogFragment() {}

    public AppCompatDialogFragment(int contentLayoutId) {
        super(contentLayoutId);
    }

    @Override public Dialog onCreateDialog(Bundle savedInstanceState) {
        return new AppCompatDialog(getContext(), getTheme());
    }

    @Override public void setupDialog(Dialog dialog, int style) {
        if (!(dialog instanceof AppCompatDialog)) {
            super.setupDialog(dialog, style);
            return;
        }
        switch (style) {
            case STYLE_NO_INPUT:
                dialog.getWindow().addFlags(WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE);
                // An input-less dialog has no title either.
            case STYLE_NO_FRAME:
            case STYLE_NO_TITLE:
                ((AppCompatDialog) dialog).supportRequestWindowFeature(Window.FEATURE_NO_TITLE);
                break;
            default:
                break;
        }
    }
}
