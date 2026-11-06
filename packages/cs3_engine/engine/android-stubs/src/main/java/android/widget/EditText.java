package android.widget;

import android.content.Context;
import android.text.Editable;
import android.text.InputType;
import android.util.AttributeSet;
import dev.akash.cs3engine.stubs.LayoutAttributes;

/** A stand-in field: Editable text, a new copy on each setText, and a selection. */
public class EditText extends TextView {
    public EditText(Context context) {
        this(context, null);
    }

    public EditText(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public EditText(Context context, AttributeSet attrs, int defStyleAttr) {
        this(context, attrs, defStyleAttr, 0);
    }

    public EditText(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
        // As Android's: editable text, multi-line until an input type or single-line says otherwise.
        setRawInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE);
        setText("", BufferType.EDITABLE);
        // Its defaults are set: the layout's text attributes again, so they win, as on Android.
        LayoutAttributes.text(this, attrs);
    }

    @Override public Editable getText() { return (Editable) super.getText(); }
    @Override public void setText(CharSequence text, BufferType type) { super.setText(text, BufferType.EDITABLE); }
    public void setSelection(int index) { setSelection(index, index); }

    public void setSelection(int start, int stop) {
        if (start < 0 || start > length() || stop < 0 || stop > length()) {
            throw new IndexOutOfBoundsException("setSelection(" + start + ", " + stop + ") out of range for length " + length());
        }
        select(start, stop);
    }

    public void selectAll() { select(0, length()); }
    public void extendSelection(int index) { setSelection(getSelectionStart(), index); }
}
