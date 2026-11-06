package androidx.preference;

import android.content.Context;
import android.content.res.TypedArray;
import android.util.AttributeSet;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.SeekBar;
import android.widget.TextView;

/**
 * A number between a minimum and a maximum, set on a slider in its row (preference_widget_seekbar_material).
 * What the person slides to is saved when they let go, or as they slide when it updates continuously.
 */
public class SeekBarPreference extends Preference {
    private int seekBarValue;
    private int min;
    private int max = 100;
    private int increment;
    private boolean trackingTouch;
    private boolean adjustable = true;
    private boolean showSeekBarValue;
    private boolean updatesContinuously;
    private TextView valueView;

    private final SeekBar.OnSeekBarChangeListener seekBarListener = new SeekBar.OnSeekBarChangeListener() {
        @Override public void onProgressChanged(SeekBar seekBar, int progress, boolean fromUser) {
            if (fromUser && (updatesContinuously || !trackingTouch)) syncValueInternal(seekBar);
            else updateLabelValue(progress + min);
        }

        @Override public void onStartTrackingTouch(SeekBar seekBar) {
            trackingTouch = true;
        }

        @Override public void onStopTrackingTouch(SeekBar seekBar) {
            trackingTouch = false;
            if (seekBar.getProgress() + min != seekBarValue) syncValueInternal(seekBar);
        }
    };

    public SeekBarPreference(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
    }

    public SeekBarPreference(Context context, AttributeSet attrs, int defStyleAttr) {
        this(context, attrs, defStyleAttr, 0);
    }

    public SeekBarPreference(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public SeekBarPreference(Context context) {
        this(context, null);
    }

    /** The icon's frame, then a column of the title over the summary (weight 1) and a row of the slider (weight 1) and its value. */
    @Override View createRow(Context context) {
        LinearLayout row = new LinearLayout(context);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.addView(iconFrame(context));
        LinearLayout column = new LinearLayout(context);
        column.setOrientation(LinearLayout.VERTICAL);
        column.addView(titleAndSummary(context), new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, 0, 1f));
        LinearLayout bar = new LinearLayout(context);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        SeekBar seekBar = new SeekBar(context);
        seekBar.setId(R.id.seekbar);
        bar.addView(seekBar, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        TextView value = new TextView(context);
        value.setId(R.id.seekbar_value);
        bar.addView(value);
        column.addView(bar);
        row.addView(column, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        return row;
    }

    @Override public void onBindViewHolder(PreferenceViewHolder holder) {
        super.onBindViewHolder(holder);
        View label = holder.findViewById(R.id.seekbar_value);
        valueView = showSeekBarValue && label instanceof TextView ? (TextView) label : null;
        if (label != null) label.setVisibility(showSeekBarValue ? View.VISIBLE : View.GONE);
        View view = holder.findViewById(R.id.seekbar);
        if (!(view instanceof SeekBar)) return;
        SeekBar seekBar = (SeekBar) view;
        seekBar.setOnSeekBarChangeListener(seekBarListener);
        seekBar.setMax(max - min);
        seekBar.setProgress(seekBarValue - min);
        updateLabelValue(seekBarValue);
        seekBar.setEnabled(isEnabled());
    }

    @Override protected Object onGetDefaultValue(TypedArray a, int index) { return a.getInt(index, 0); }

    @Override protected void onSetInitialValue(Object defaultValue) {
        if (defaultValue == null) defaultValue = 0;
        setValue(getPersistedInt((Integer) defaultValue));
    }

    public int getMin() { return min; }

    public void setMin(int min) {
        if (min > max) min = max;
        if (min == this.min) return;
        this.min = min;
        notifyChanged();
    }

    public final int getSeekBarIncrement() { return increment; }

    public final void setSeekBarIncrement(int seekBarIncrement) {
        if (seekBarIncrement == increment) return;
        increment = Math.min(max - min, Math.abs(seekBarIncrement));
        notifyChanged();
    }

    public int getMax() { return max; }

    public final void setMax(int max) {
        if (max < min) max = min;
        if (max == this.max) return;
        this.max = max;
        notifyChanged();
    }

    public boolean isAdjustable() { return adjustable; }
    public void setAdjustable(boolean adjustable) { this.adjustable = adjustable; }
    public boolean getUpdatesContinuously() { return updatesContinuously; }
    public void setUpdatesContinuously(boolean updatesContinuously) { this.updatesContinuously = updatesContinuously; }
    public boolean getShowSeekBarValue() { return showSeekBarValue; }

    public void setShowSeekBarValue(boolean showSeekBarValue) {
        this.showSeekBarValue = showSeekBarValue;
        notifyChanged();
    }

    public int getValue() { return seekBarValue; }

    public void setValue(int seekBarValue) { setValueInternal(seekBarValue, true); }

    private void setValueInternal(int value, boolean notifyChanged) {
        if (value < min) value = min;
        if (value > max) value = max;
        if (value == seekBarValue) return;
        seekBarValue = value;
        updateLabelValue(seekBarValue);
        persistInt(value);
        if (notifyChanged) notifyChanged();
    }

    /** The slider's value, if the change listener agrees; else the slider goes back. */
    private void syncValueInternal(SeekBar seekBar) {
        int value = min + seekBar.getProgress();
        if (value == seekBarValue) return;
        if (callChangeListener(value)) {
            setValueInternal(value, false);
        } else {
            seekBar.setProgress(seekBarValue - min);
            updateLabelValue(seekBarValue);
        }
    }

    private void updateLabelValue(int value) {
        if (valueView != null) valueView.setText(String.valueOf(value));
    }
}
