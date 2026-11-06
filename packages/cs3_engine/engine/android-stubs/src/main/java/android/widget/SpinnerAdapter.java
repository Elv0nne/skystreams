package android.widget;

import android.view.View;
import android.view.ViewGroup;

/** A dropdown's items. */
public interface SpinnerAdapter extends Adapter {
    View getDropDownView(int position, View convertView, ViewGroup parent);
}
