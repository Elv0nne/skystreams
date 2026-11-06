package androidx.preference;

import android.content.Context;
import android.content.res.TypedArray;
import android.text.TextUtils;
import android.util.AttributeSet;
import android.view.View;
import android.widget.TextView;

/** An on/off preference: a tap toggles it, if its listener agrees; its value is saved. */
public abstract class TwoStatePreference extends Preference {
    protected boolean mChecked;
    private boolean checkedSet;
    private CharSequence summaryOn;
    private CharSequence summaryOff;

    public TwoStatePreference(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
    }

    public TwoStatePreference(Context context, AttributeSet attrs, int defStyleAttr) {
        this(context, attrs, defStyleAttr, 0);
    }

    public TwoStatePreference(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public TwoStatePreference(Context context) {
        this(context, null);
    }

    @Override protected void onClick() {
        super.onClick();
        boolean newValue = !isChecked();
        if (callChangeListener(newValue)) setChecked(newValue);
    }

    public boolean isChecked() { return mChecked; }

    /** As Android's: saved the first time, and whenever it changes. */
    public void setChecked(boolean checked) {
        boolean changed = mChecked != checked;
        if (!changed && checkedSet) return;
        mChecked = checked;
        checkedSet = true;
        persistBoolean(checked);
        if (changed) notifyChanged();
    }

    public void setSummaryOn(CharSequence summary) {
        summaryOn = summary;
        if (isChecked()) notifyChanged();
    }

    public CharSequence getSummaryOn() { return summaryOn; }
    public void setSummaryOn(int summaryResId) { setSummaryOn(getContext().getString(summaryResId)); }

    public void setSummaryOff(CharSequence summary) {
        summaryOff = summary;
        if (!isChecked()) notifyChanged();
    }

    public CharSequence getSummaryOff() { return summaryOff; }
    public void setSummaryOff(int summaryResId) { setSummaryOff(getContext().getString(summaryResId)); }

    @Override protected Object onGetDefaultValue(TypedArray a, int index) { return a.getBoolean(index, false); }

    @Override protected void onSetInitialValue(Object defaultValue) {
        if (defaultValue == null) defaultValue = false;
        setChecked(getPersistedBoolean((Boolean) defaultValue));
    }

    protected void syncSummaryView(PreferenceViewHolder holder) {
        syncSummaryView(holder.findViewById(android.R.id.summary));
    }

    /** The summary for its state when it has one, else the summary, as Android's. */
    protected void syncSummaryView(View view) {
        if (!(view instanceof TextView)) return;
        TextView summaryView = (TextView) view;
        CharSequence shown = mChecked && !TextUtils.isEmpty(summaryOn) ? summaryOn
            : !mChecked && !TextUtils.isEmpty(summaryOff) ? summaryOff
            : getSummary();
        if (TextUtils.isEmpty(shown)) {
            summaryView.setVisibility(View.GONE);
            return;
        }
        summaryView.setText(shown);
        summaryView.setVisibility(View.VISIBLE);
    }
}
