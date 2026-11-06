package com.google.android.material.textfield;

import android.content.Context;
import android.util.AttributeSet;
import android.view.View;
import android.view.ViewParent;
import android.widget.EditText;

/** Material's field: inside a TextInputLayout with a hint, that hint is its own, as Material's is. */
public class TextInputEditText extends EditText {
    public TextInputEditText(Context context) {
        this(context, null);
    }

    public TextInputEditText(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public TextInputEditText(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr, 0);
    }

    @Override public CharSequence getHint() {
        TextInputLayout layout = layout();
        return layout != null && layout.getHint() != null ? layout.getHint() : super.getHint();
    }

    private TextInputLayout layout() {
        ViewParent parent = getParent();
        while (parent instanceof View) {
            if (parent instanceof TextInputLayout) return (TextInputLayout) parent;
            parent = ((View) parent).getParent();
        }
        return null;
    }
}
