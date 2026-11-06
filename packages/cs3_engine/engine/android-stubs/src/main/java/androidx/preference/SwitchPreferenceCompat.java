package androidx.preference;

import android.content.Context;
import android.util.AttributeSet;
import android.view.View;
import android.widget.CompoundButton;
import androidx.appcompat.widget.SwitchCompat;

/**
 * An on/off preference whose row ends in a switch. The switch follows it; a change made on the switch goes
 * through the change listener, which can put it back, as Android's.
 */
public class SwitchPreferenceCompat extends TwoStatePreference {
    private final CompoundButton.OnCheckedChangeListener switchListener = (button, isChecked) -> {
        if (!callChangeListener(isChecked)) {
            button.setChecked(!isChecked);
            return;
        }
        setChecked(isChecked);
    };

    public SwitchPreferenceCompat(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
    }

    public SwitchPreferenceCompat(Context context, AttributeSet attrs, int defStyleAttr) {
        this(context, attrs, defStyleAttr, 0);
    }

    public SwitchPreferenceCompat(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public SwitchPreferenceCompat(Context context) {
        this(context, null);
    }

    /** preference_widget_switch_compat: the row takes the tap, not the switch. */
    @Override View onCreateWidget(Context context) {
        SwitchCompat widget = new SwitchCompat(context);
        widget.setId(R.id.switchWidget);
        widget.setFocusable(false);
        widget.setClickable(false);
        return widget;
    }

    @Override public void onBindViewHolder(PreferenceViewHolder holder) {
        super.onBindViewHolder(holder);
        View view = holder.findViewById(R.id.switchWidget);
        if (view instanceof SwitchCompat) {
            SwitchCompat widget = (SwitchCompat) view;
            widget.setOnCheckedChangeListener(null);
            widget.setChecked(mChecked);
            widget.setOnCheckedChangeListener(switchListener);
        }
        syncSummaryView(holder);
    }
}
