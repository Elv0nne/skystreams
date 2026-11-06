package androidx.preference;

import android.view.View;
import androidx.recyclerview.widget.RecyclerView;

/** A preference's row in its list. */
public class PreferenceViewHolder extends RecyclerView.ViewHolder {
    private boolean dividerAllowedAbove;
    private boolean dividerAllowedBelow;

    PreferenceViewHolder(View itemView) {
        super(itemView);
    }

    public static PreferenceViewHolder createInstanceForTests(View itemView) {
        return new PreferenceViewHolder(itemView);
    }

    public View findViewById(int id) { return itemView.findViewById(id); }
    public boolean isDividerAllowedAbove() { return dividerAllowedAbove; }
    public void setDividerAllowedAbove(boolean allowed) { dividerAllowedAbove = allowed; }
    public boolean isDividerAllowedBelow() { return dividerAllowedBelow; }
    public void setDividerAllowedBelow(boolean allowed) { dividerAllowedBelow = allowed; }
}
