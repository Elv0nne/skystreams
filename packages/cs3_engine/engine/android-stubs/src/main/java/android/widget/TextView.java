package android.widget;

import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;
import android.text.Editable;
import android.text.InputType;
import android.text.SpannableStringBuilder;
import android.text.TextPaint;
import android.text.TextWatcher;
import android.util.AttributeSet;
import android.util.TypedValue;
import android.view.KeyEvent;
import android.view.View;
import android.view.inputmethod.EditorInfo;
import dev.akash.cs3engine.stubs.LayoutAttributes;
import java.util.ArrayList;
import java.util.List;

/**
 * A stand-in text view: its words, hint, input type, size and style, and its watchers. Its size is
 * Android's default (14sp) until set; nothing is measured.
 */
public class TextView extends View {
    public enum BufferType { NORMAL, SPANNABLE, EDITABLE }

    public interface OnEditorActionListener {
        boolean onEditorAction(TextView v, int actionId, KeyEvent event);
    }

    private CharSequence text = "";
    private CharSequence hint;
    private CharSequence error;
    private int inputType = InputType.TYPE_NULL;
    private int imeOptions = EditorInfo.IME_NULL;
    private final TextPaint paint = new TextPaint();
    private Typeface typeface;
    private ColorStateList textColors = ColorStateList.valueOf(0xFFFFFFFF);
    private int gravity = 0x00800033;
    private int maxLines = Integer.MAX_VALUE;
    private boolean allCaps;
    private boolean selectable;
    private int selectionStart = -1;
    private int selectionEnd = -1;
    private OnEditorActionListener editorAction;
    private List<TextWatcher> watchers;

    public TextView(Context context) {
        this(context, null);
    }

    public TextView(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public TextView(Context context, AttributeSet attrs, int defStyleAttr) {
        this(context, attrs, defStyleAttr, 0);
    }

    public TextView(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
        paint.setTextSize(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 14f, getResources().getDisplayMetrics()));
        LayoutAttributes.text(this, attrs);
    }

    /** The app's string [resid]: Android's common ones; the extension's aren't the app's, so they read empty. */
    private String appString(int resid) {
        return getContext() != null ? getContext().getString(resid) : "";
    }

    public final void setText(CharSequence text) { setText(text, BufferType.NORMAL); }
    public final void setText(int resid) { setText(appString(resid)); }
    public final void setText(int resid, BufferType type) { setText(appString(resid), type); }
    public final void setText(char[] text, int start, int len) { setText(new String(text, start, len)); }

    /** As Android's: watchers hear before, on and after, and with watchers (or as asked) the text is Editable. */
    public void setText(CharSequence text, BufferType type) {
        CharSequence before = this.text;
        CharSequence next = text == null ? "" : text;
        List<TextWatcher> heard = watchers == null || watchers.isEmpty() ? null : new ArrayList<>(watchers);
        if (type == BufferType.EDITABLE || (heard != null && !(next instanceof Editable))) next = new SpannableStringBuilder(next);
        if (heard != null) for (TextWatcher watcher : heard) watcher.beforeTextChanged(before, 0, before.length(), next.length());
        this.text = next;
        changed();
        if (heard != null) {
            for (TextWatcher watcher : heard) watcher.onTextChanged(next, 0, before.length(), next.length());
            for (TextWatcher watcher : heard) watcher.afterTextChanged((Editable) next);
        }
    }

    public CharSequence getText() { return text; }
    public int length() { return text.length(); }
    public final void append(CharSequence more) { append(more, 0, more.length()); }

    public void append(CharSequence more, int start, int end) {
        if (text instanceof Editable) {
            ((Editable) text).append(more, start, end);
            changed();
        } else {
            setText(new StringBuilder(text).append(more, start, end));
        }
    }

    public void setHint(CharSequence hint) {
        this.hint = hint;
        changed();
    }

    public final void setHint(int resid) { setHint(appString(resid)); }
    public CharSequence getHint() { return hint; }
    public void setError(CharSequence error) { this.error = error; }
    public void setError(CharSequence error, Drawable icon) { this.error = error; }
    public CharSequence getError() { return error; }

    public void setInputType(int type) {
        inputType = type;
        changed();
    }

    public void setRawInputType(int type) { setInputType(type); }
    public int getInputType() { return inputType; }
    public void setSingleLine() { setSingleLine(true); }

    /** As Android's: an editable text field loses (or gets) the multi-line flag; one line at most. */
    public void setSingleLine(boolean singleLine) {
        if ((inputType & InputType.TYPE_MASK_CLASS) == InputType.TYPE_CLASS_TEXT) {
            inputType = singleLine ? inputType & ~InputType.TYPE_TEXT_FLAG_MULTI_LINE : inputType | InputType.TYPE_TEXT_FLAG_MULTI_LINE;
        }
        if (singleLine) maxLines = 1;
        changed();
    }

    public void setLines(int lines) { maxLines = lines; }
    public void setMaxLines(int maxLines) { this.maxLines = maxLines; }
    public int getMaxLines() { return maxLines; }
    public void setMinLines(int minLines) {}
    public void setTextSize(float size) { setTextSize(TypedValue.COMPLEX_UNIT_SP, size); }

    public void setTextSize(int unit, float size) {
        paint.setTextSize(TypedValue.applyDimension(unit, size, getResources().getDisplayMetrics()));
        changed();
    }

    public float getTextSize() { return paint.getTextSize(); }

    public void setTypeface(Typeface tf) {
        typeface = tf;
        paint.setTypeface(tf);
        changed();
    }

    /** As Android's: [tf] in [style], with fake bold where that face isn't bold itself. */
    public void setTypeface(Typeface tf, int style) {
        if (style > 0) {
            Typeface styled = tf == null ? Typeface.defaultFromStyle(style) : Typeface.create(tf, style);
            setTypeface(styled);
            paint.setFakeBoldText((style & ~styled.getStyle() & Typeface.BOLD) != 0);
        } else {
            paint.setFakeBoldText(false);
            setTypeface(tf);
        }
    }

    public Typeface getTypeface() { return typeface; }
    public TextPaint getPaint() { return paint; }

    public void setPaintFlags(int flags) {
        paint.setFlags(flags);
        changed();
    }

    public int getPaintFlags() { return paint.getFlags(); }
    public void setTextColor(int color) { textColors = ColorStateList.valueOf(color); }

    public void setTextColor(ColorStateList colors) {
        if (colors == null) throw new NullPointerException("colors");
        textColors = colors;
    }

    public final ColorStateList getTextColors() { return textColors; }
    public final int getCurrentTextColor() { return textColors.getDefaultColor(); }
    public void setGravity(int gravity) { this.gravity = gravity; }
    public int getGravity() { return gravity; }
    public void setAllCaps(boolean allCaps) { this.allCaps = allCaps; }
    public boolean isAllCaps() { return allCaps; }
    public void setImeOptions(int imeOptions) { this.imeOptions = imeOptions; }
    public int getImeOptions() { return imeOptions; }
    public void setOnEditorActionListener(OnEditorActionListener listener) { editorAction = listener; }

    /** The keyboard's action key: the extension's listener hears it; there's no keyboard to act otherwise. */
    public void onEditorAction(int actionCode) {
        if (editorAction != null) editorAction.onEditorAction(this, actionCode, null);
    }

    public void addTextChangedListener(TextWatcher watcher) {
        if (watchers == null) watchers = new ArrayList<>();
        watchers.add(watcher);
    }

    public void removeTextChangedListener(TextWatcher watcher) {
        if (watchers != null) watchers.remove(watcher);
    }

    public void setTextIsSelectable(boolean selectable) { this.selectable = selectable; }
    public boolean isTextSelectable() { return selectable; }
    public int getSelectionStart() { return selectionStart; }
    public int getSelectionEnd() { return selectionEnd; }

    void select(int start, int end) {
        selectionStart = start;
        selectionEnd = end;
    }

    public void setCompoundDrawables(Drawable left, Drawable top, Drawable right, Drawable bottom) {}
    public void setCompoundDrawablesWithIntrinsicBounds(Drawable left, Drawable top, Drawable right, Drawable bottom) {}
    public void setCompoundDrawablesWithIntrinsicBounds(int left, int top, int right, int bottom) {}
    public void setCompoundDrawablesRelativeWithIntrinsicBounds(Drawable start, Drawable top, Drawable end, Drawable bottom) {}
    public void setCompoundDrawablesRelativeWithIntrinsicBounds(int start, int top, int end, int bottom) {}
    public void setCompoundDrawablePadding(int pad) {}
}
