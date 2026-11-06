package androidx.fragment.app;

import android.app.Activity;
import android.app.Dialog;
import android.content.Context;
import android.content.DialogInterface;
import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import androidx.activity.ComponentDialog;
import dev.akash.cs3engine.stubs.MainThread;
import dev.akash.cs3engine.stubs.Ui;

/**
 * A fragment shown as a dialog, as Fragment 1.8.9's: the dialog is made when its view is (onCreateDialog,
 * a ComponentDialog), holds its view, shows when it starts, and goes when its view does. Dismissing it,
 * or its dialog closing, removes the fragment. Its dialog is the fragment's own (Ui.own), so the window
 * that shows says whose it is.
 */
public class DialogFragment extends Fragment implements DialogInterface.OnCancelListener, DialogInterface.OnDismissListener {
    public static final int STYLE_NORMAL = 0;
    public static final int STYLE_NO_TITLE = 1;
    public static final int STYLE_NO_FRAME = 2;
    public static final int STYLE_NO_INPUT = 3;

    private int style = STYLE_NORMAL;
    private int theme;
    private boolean cancelable = true;
    private boolean showsDialog = true;
    private int backStackId = -1;
    private boolean creatingDialog;
    private boolean dialogCreated;
    private Dialog dialog;
    private boolean viewDestroyed;
    private boolean dismissed;
    private boolean shownByMe;

    public DialogFragment() {}

    public DialogFragment(int contentLayoutId) {
        super(contentLayoutId);
    }

    public void setStyle(int style, int theme) {
        this.style = style;
        if (theme != 0) this.theme = theme;
    }

    public void show(FragmentManager manager, String tag) {
        dismissed = false;
        shownByMe = true;
        manager.beginTransaction().setReorderingAllowed(true).add(this, tag).commit();
    }

    public int show(FragmentTransaction transaction, String tag) {
        dismissed = false;
        shownByMe = true;
        transaction.add(this, tag);
        viewDestroyed = false;
        backStackId = transaction.commit();
        return backStackId;
    }

    public void showNow(FragmentManager manager, String tag) {
        dismissed = false;
        shownByMe = true;
        manager.beginTransaction().setReorderingAllowed(true).add(this, tag).commitNow();
    }

    public void dismiss() { dismissInternal(false, false, false); }
    public void dismissNow() { dismissInternal(false, false, true); }
    public void dismissAllowingStateLoss() { dismissInternal(true, false, false); }

    private void dismissInternal(boolean allowStateLoss, boolean fromOnDismiss, boolean immediate) {
        if (dismissed) return;
        dismissed = true;
        shownByMe = false;
        if (dialog != null) {
            // As Android's: the listener goes, and onDismiss is called here instead, before onDestroy.
            Dialog closing = dialog;
            closing.setOnDismissListener(null);
            closing.dismiss();
            if (!fromOnDismiss) {
                if (MainThread.isMainThread()) onDismiss(closing);
                else MainThread.post(() -> onDismiss(closing));
            }
        }
        viewDestroyed = true;
        if (backStackId >= 0) {
            if (immediate) getParentFragmentManager().popBackStackImmediate(backStackId, FragmentManager.POP_BACK_STACK_INCLUSIVE);
            else getParentFragmentManager().popBackStack(backStackId, FragmentManager.POP_BACK_STACK_INCLUSIVE);
            backStackId = -1;
            return;
        }
        FragmentTransaction transaction = getParentFragmentManager().beginTransaction().setReorderingAllowed(true).remove(this);
        if (immediate) transaction.commitNow();
        else if (allowStateLoss) transaction.commitAllowingStateLoss();
        else transaction.commit();
    }

    public Dialog getDialog() { return dialog; }

    public final Dialog requireDialog() {
        if (dialog == null) throw new IllegalStateException("DialogFragment " + this + " does not have a Dialog.");
        return dialog;
    }

    public final ComponentDialog requireComponentDialog() {
        Dialog shown = requireDialog();
        if (!(shown instanceof ComponentDialog)) {
            throw new IllegalStateException("DialogFragment " + this + " did not return a ComponentDialog instance from requireDialog(). The actual Dialog is " + shown);
        }
        return (ComponentDialog) shown;
    }

    public int getTheme() { return theme; }

    public void setCancelable(boolean cancelable) {
        this.cancelable = cancelable;
        if (dialog != null) dialog.setCancelable(cancelable);
    }

    public boolean isCancelable() { return cancelable; }
    public void setShowsDialog(boolean showsDialog) { this.showsDialog = showsDialog; }
    public boolean getShowsDialog() { return showsDialog; }

    @Override public void onAttach(Context context) {
        super.onAttach(context);
        if (!shownByMe) dismissed = false;
    }

    @Override public void onDetach() {
        super.onDetach();
        if (!shownByMe && !dismissed) dismissed = true;
    }

    @Override public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        showsDialog = containerId == 0;
    }

    @Override public LayoutInflater onGetLayoutInflater(Bundle savedInstanceState) {
        LayoutInflater inflater = super.onGetLayoutInflater(savedInstanceState);
        if (!showsDialog || creatingDialog) return inflater;
        prepareDialog(savedInstanceState);
        return dialog != null ? inflater.cloneInContext(dialog.getContext()) : inflater;
    }

    private void prepareDialog(Bundle savedInstanceState) {
        if (!showsDialog || dialogCreated) return;
        try {
            creatingDialog = true;
            dialog = onCreateDialog(savedInstanceState);
            if (showsDialog) {
                setupDialog(dialog, style);
                Context context = getContext();
                if (context instanceof Activity) dialog.setOwnerActivity((Activity) context);
                dialog.setCancelable(cancelable);
                dialog.setOnCancelListener(this);
                dialog.setOnDismissListener(this);
                Ui.own(dialog, this);
                dialogCreated = true;
            } else {
                dialog = null;
            }
        } finally {
            creatingDialog = false;
        }
    }

    public void setupDialog(Dialog dialog, int style) {
        switch (style) {
            case STYLE_NO_INPUT:
                dialog.getWindow().addFlags(WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE);
                // An input-less dialog has no title either.
            case STYLE_NO_FRAME:
            case STYLE_NO_TITLE:
                dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
                break;
            default:
                break;
        }
    }

    public Dialog onCreateDialog(Bundle savedInstanceState) {
        return new ComponentDialog(requireContext(), getTheme());
    }

    @Override public void onCancel(DialogInterface dialog) {}

    @Override public void onDismiss(DialogInterface dialog) {
        if (!viewDestroyed) dismissInternal(true, true, false);
    }

    @Override void onViewAvailable(View view) {
        if (!showsDialog) return;
        if (view.getParent() != null) throw new IllegalStateException("DialogFragment can not be attached to a container view");
        if (dialog != null) dialog.setContentView(view);
    }

    @Override View findContainerView(int id) {
        if (getView() != null) return super.findContainerView(id);
        return dialog != null ? dialog.findViewById(id) : null;
    }

    @Override public void onStart() {
        super.onStart();
        if (dialog != null) {
            viewDestroyed = false;
            dialog.show();
        }
    }

    @Override public void onStop() {
        super.onStop();
        if (dialog != null) dialog.hide();
    }

    @Override public void onDestroyView() {
        super.onDestroyView();
        if (dialog != null) {
            viewDestroyed = true;
            dialog.setOnDismissListener(null);
            dialog.dismiss();
            if (!dismissed) onDismiss(dialog);
            dialog = null;
            dialogCreated = false;
        }
    }
}
