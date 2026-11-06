package androidx.preference;

import android.content.Context;
import android.graphics.drawable.Drawable;
import android.util.AttributeSet;

/** A preference set in an alert its fragment opens; OK and Cancel unless it says otherwise. */
public abstract class DialogPreference extends Preference {
    private CharSequence dialogTitle;
    private CharSequence dialogMessage;
    private Drawable dialogIcon;
    private CharSequence positiveButtonText;
    private CharSequence negativeButtonText;

    public DialogPreference(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
        positiveButtonText = context.getString(android.R.string.ok);
        negativeButtonText = context.getString(android.R.string.cancel);
    }

    public DialogPreference(Context context, AttributeSet attrs, int defStyleAttr) {
        this(context, attrs, defStyleAttr, 0);
    }

    public DialogPreference(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public DialogPreference(Context context) {
        this(context, null);
    }

    public void setDialogTitle(CharSequence dialogTitle) { this.dialogTitle = dialogTitle; }
    public void setDialogTitle(int dialogTitleResId) { setDialogTitle(getContext().getString(dialogTitleResId)); }
    public CharSequence getDialogTitle() { return dialogTitle; }
    public void setDialogMessage(CharSequence dialogMessage) { this.dialogMessage = dialogMessage; }
    public void setDialogMessage(int dialogMessageResId) { setDialogMessage(getContext().getString(dialogMessageResId)); }
    public CharSequence getDialogMessage() { return dialogMessage; }
    public void setDialogIcon(Drawable dialogIcon) { this.dialogIcon = dialogIcon; }
    public void setDialogIcon(int dialogIconRes) {}
    public Drawable getDialogIcon() { return dialogIcon; }
    public void setPositiveButtonText(CharSequence positiveButtonText) { this.positiveButtonText = positiveButtonText; }
    public void setPositiveButtonText(int positiveButtonTextResId) { setPositiveButtonText(getContext().getString(positiveButtonTextResId)); }
    public CharSequence getPositiveButtonText() { return positiveButtonText; }
    public void setNegativeButtonText(CharSequence negativeButtonText) { this.negativeButtonText = negativeButtonText; }
    public void setNegativeButtonText(int negativeButtonTextResId) { setNegativeButtonText(getContext().getString(negativeButtonTextResId)); }
    public CharSequence getNegativeButtonText() { return negativeButtonText; }

    /** Its fragment opens its alert (PreferenceFragmentCompat.onDisplayPreferenceDialog). */
    @Override protected void onClick() {
        getPreferenceManager().showDialog(this);
    }
}
