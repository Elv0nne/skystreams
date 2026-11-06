package androidx.preference;

import android.content.Context;
import android.content.res.TypedArray;
import android.text.TextUtils;
import android.util.AttributeSet;
import android.widget.EditText;

/** A text set in a text alert. */
public class EditTextPreference extends DialogPreference {
    public interface OnBindEditTextListener {
        void onBindEditText(EditText editText);
    }

    /** The text as the summary, or "Not set". */
    public static final class SimpleSummaryProvider implements SummaryProvider<EditTextPreference> {
        private static SimpleSummaryProvider instance;

        private SimpleSummaryProvider() {}

        public static synchronized SimpleSummaryProvider getInstance() {
            if (instance == null) instance = new SimpleSummaryProvider();
            return instance;
        }

        @Override public CharSequence provideSummary(EditTextPreference preference) {
            return TextUtils.isEmpty(preference.getText()) ? NOT_SET : preference.getText();
        }
    }

    private String text;
    private OnBindEditTextListener onBindEditTextListener;

    public EditTextPreference(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
    }

    public EditTextPreference(Context context, AttributeSet attrs, int defStyleAttr) {
        this(context, attrs, defStyleAttr, 0);
    }

    public EditTextPreference(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public EditTextPreference(Context context) {
        this(context, null);
    }

    public void setText(String text) {
        this.text = text;
        persistString(text);
        notifyChanged();
    }

    public String getText() { return text; }
    @Override protected Object onGetDefaultValue(TypedArray a, int index) { return a.getString(index); }
    @Override protected void onSetInitialValue(Object defaultValue) { setText(getPersistedString((String) defaultValue)); }
    public void setOnBindEditTextListener(OnBindEditTextListener listener) { onBindEditTextListener = listener; }
    OnBindEditTextListener getOnBindEditTextListener() { return onBindEditTextListener; }
}
