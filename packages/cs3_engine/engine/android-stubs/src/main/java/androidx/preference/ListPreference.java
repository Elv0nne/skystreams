package androidx.preference;

import android.content.Context;
import android.content.res.TypedArray;
import android.text.TextUtils;
import android.util.AttributeSet;

/** One of its entries, chosen in an alert of choices; the value saved is the entry's value. */
public class ListPreference extends DialogPreference {
    /** The chosen entry as the summary, or "Not set". */
    public static final class SimpleSummaryProvider implements SummaryProvider<ListPreference> {
        private static SimpleSummaryProvider instance;

        private SimpleSummaryProvider() {}

        public static synchronized SimpleSummaryProvider getInstance() {
            if (instance == null) instance = new SimpleSummaryProvider();
            return instance;
        }

        @Override public CharSequence provideSummary(ListPreference preference) {
            return TextUtils.isEmpty(preference.getEntry()) ? NOT_SET : preference.getEntry();
        }
    }

    private CharSequence[] entries;
    private CharSequence[] entryValues;
    private String value;
    private String summaryFormat;
    private boolean valueSet;

    public ListPreference(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
    }

    public ListPreference(Context context, AttributeSet attrs, int defStyleAttr) {
        this(context, attrs, defStyleAttr, 0);
    }

    public ListPreference(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public ListPreference(Context context) {
        this(context, null);
    }

    public void setEntries(CharSequence[] entries) { this.entries = entries; }
    public void setEntries(int entriesResId) { setEntries(getContext().getResources().getTextArray(entriesResId)); }
    public CharSequence[] getEntries() { return entries; }
    public void setEntryValues(CharSequence[] entryValues) { this.entryValues = entryValues; }
    public void setEntryValues(int entryValuesResId) { setEntryValues(getContext().getResources().getTextArray(entryValuesResId)); }
    public CharSequence[] getEntryValues() { return entryValues; }

    @Override public void setSummary(CharSequence summary) {
        super.setSummary(summary);
        summaryFormat = summary == null ? null : summary.toString();
    }

    /** The provider's, else the summary with the entry in its %s, as Android's. */
    @SuppressWarnings("unchecked")
    @Override public CharSequence getSummary() {
        if (getSummaryProvider() != null) return getSummaryProvider().provideSummary(this);
        CharSequence summary = super.getSummary();
        if (summaryFormat == null) return summary;
        CharSequence entry = getEntry();
        String formatted = String.format(summaryFormat, entry == null ? "" : entry);
        return TextUtils.equals(formatted, summary) ? summary : formatted;
    }

    /** As Android's: saved the first time, and whenever it changes. */
    public void setValue(String value) {
        boolean changed = !TextUtils.equals(this.value, value);
        if (!changed && valueSet) return;
        this.value = value;
        valueSet = true;
        persistString(value);
        if (changed) notifyChanged();
    }

    public String getValue() { return value; }

    public CharSequence getEntry() {
        int index = findIndexOfValue(value);
        return index >= 0 && entries != null ? entries[index] : null;
    }

    public int findIndexOfValue(String value) {
        if (value == null || entryValues == null) return -1;
        for (int i = entryValues.length - 1; i >= 0; i--) if (TextUtils.equals(entryValues[i].toString(), value)) return i;
        return -1;
    }

    public void setValueIndex(int index) {
        if (entryValues != null) setValue(entryValues[index].toString());
    }

    @Override protected Object onGetDefaultValue(TypedArray a, int index) { return a.getString(index); }
    @Override protected void onSetInitialValue(Object defaultValue) { setValue(getPersistedString((String) defaultValue)); }
}
