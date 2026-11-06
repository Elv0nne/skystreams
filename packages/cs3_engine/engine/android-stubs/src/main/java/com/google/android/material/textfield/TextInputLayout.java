package com.google.android.material.textfield;

import android.content.Context;
import android.util.AttributeSet;
import android.view.View;
import android.view.ViewGroup;
import android.widget.EditText;
import android.widget.LinearLayout;
import dev.akash.cs3engine.stubs.LayoutAttributes;

/** Material's labelled field: a column holding the field, with the hint, error and helper text. */
public class TextInputLayout extends LinearLayout {
    private CharSequence hint;
    private CharSequence error;
    private CharSequence helperText;

    public TextInputLayout(Context context) {
        this(context, null);
    }

    public TextInputLayout(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public TextInputLayout(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr, 0);
        setOrientation(VERTICAL);
        LayoutAttributes.hint(this, attrs);
    }

    /** The field inside it: the first one, however deep. */
    public EditText getEditText() { return firstField(this); }

    private static EditText firstField(ViewGroup group) {
        for (int i = 0; i < group.getChildCount(); i++) {
            View child = group.getChildAt(i);
            if (child instanceof EditText) return (EditText) child;
            if (child instanceof ViewGroup) {
                EditText inner = firstField((ViewGroup) child);
                if (inner != null) return inner;
            }
        }
        return null;
    }

    public void setHint(CharSequence hint) {
        this.hint = hint;
        changed();
    }

    public CharSequence getHint() { return hint; }
    public void setError(CharSequence error) { this.error = error; }
    public CharSequence getError() { return error; }
    public void setErrorEnabled(boolean enabled) {}
    public void setHelperText(CharSequence helperText) { this.helperText = helperText; }
    public CharSequence getHelperText() { return helperText; }
}
