package android.widget;

import android.content.Context;
import android.util.AttributeSet;
import android.view.View;
import android.view.ViewGroup;
import dev.akash.cs3engine.stubs.LayoutAttributes;

/** A stand-in radio group: one radio checked at most, by a tap or by id; its listener hears each change once. */
public class RadioGroup extends LinearLayout {
    public interface OnCheckedChangeListener {
        void onCheckedChanged(RadioGroup group, int checkedId);
    }

    private int checkedId = View.NO_ID;
    private boolean protectFromCheckedChange;
    private OnCheckedChangeListener listener;

    /** A radio checked by a tap unchecks the one before it. */
    private final CompoundButton.OnCheckedChangeListener tracker = (button, isChecked) -> {
        if (protectFromCheckedChange || !isChecked) return;
        protectFromCheckedChange = true;
        if (checkedId != View.NO_ID && checkedId != button.getId()) setCheckedStateForView(checkedId, false);
        protectFromCheckedChange = false;
        setCheckedId(button.getId());
    };

    public RadioGroup(Context context) {
        this(context, null);
    }

    public RadioGroup(Context context, AttributeSet attrs) {
        super(context, attrs);
        setOrientation(VERTICAL);
        // Vertical by default: the layout's orientation again, so it wins, as on Android.
        LayoutAttributes.orientation(this, attrs);
    }

    @Override public void addView(View child, int index, ViewGroup.LayoutParams params) {
        if (child instanceof RadioButton) {
            RadioButton button = (RadioButton) child;
            if (button.getId() == View.NO_ID) button.setId(View.generateViewId());
            if (button.isChecked()) {
                protectFromCheckedChange = true;
                if (checkedId != View.NO_ID) setCheckedStateForView(checkedId, false);
                protectFromCheckedChange = false;
                setCheckedId(button.getId());
            }
            button.setGroupListener(tracker);
        }
        super.addView(child, index, params);
    }

    public void check(int id) {
        if (id != View.NO_ID && id == checkedId) return;
        protectFromCheckedChange = true;
        if (checkedId != View.NO_ID) setCheckedStateForView(checkedId, false);
        if (id != View.NO_ID) setCheckedStateForView(id, true);
        protectFromCheckedChange = false;
        setCheckedId(id);
    }

    public void clearCheck() { check(View.NO_ID); }
    public int getCheckedRadioButtonId() { return checkedId; }
    public void setOnCheckedChangeListener(OnCheckedChangeListener listener) { this.listener = listener; }

    private void setCheckedId(int id) {
        if (id == checkedId) return;
        checkedId = id;
        changed();
        if (listener != null) listener.onCheckedChanged(this, checkedId);
    }

    private void setCheckedStateForView(int viewId, boolean checked) {
        View view = findViewById(viewId);
        if (view instanceof RadioButton) ((RadioButton) view).setChecked(checked);
    }
}
