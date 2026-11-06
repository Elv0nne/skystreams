package androidx.preference;

import android.view.ViewGroup;
import androidx.recyclerview.widget.RecyclerView;
import dev.akash.cs3engine.stubs.MainThread;
import java.util.ArrayList;
import java.util.List;

/**
 * A screen's rows: its visible preferences, a category's own after it, one row each. A preference that
 * changes binds its row again at once; a change of the hierarchy rebuilds the rows after the current
 * main-thread task, as Android's adapter does.
 */
public class PreferenceGroupAdapter extends RecyclerView.Adapter<PreferenceViewHolder> implements Preference.OnPreferenceChangeInternalListener {
    private final PreferenceGroup group;
    private List<Preference> all = new ArrayList<>();
    private List<Preference> visible = new ArrayList<>();
    /** One preference per row type: its row is the type's. */
    private final List<Preference> rowTypes = new ArrayList<>();
    private boolean syncPosted;

    public PreferenceGroupAdapter(PreferenceGroup preferenceGroup) {
        group = preferenceGroup;
        group.setOnPreferenceChangeInternalListener(this);
        update();
    }

    private void update() {
        for (Preference preference : all) preference.setOnPreferenceChangeInternalListener(null);
        List<Preference> everything = new ArrayList<>();
        flatten(group, everything, false);
        List<Preference> shown = new ArrayList<>();
        flatten(group, shown, true);
        all = everything;
        visible = shown;
        for (Preference preference : all) preference.setOnPreferenceChangeInternalListener(this);
        notifyDataSetChanged();
    }

    private static void flatten(PreferenceGroup group, List<Preference> out, boolean onlyVisible) {
        for (int i = 0; i < group.getPreferenceCount(); i++) {
            Preference preference = group.getPreference(i);
            if (onlyVisible && !preference.isVisible()) continue;
            out.add(preference);
            if (preference instanceof PreferenceGroup && ((PreferenceGroup) preference).isOnSameScreenAsChildren()) {
                flatten((PreferenceGroup) preference, out, onlyVisible);
            }
        }
    }

    public Preference getItem(int position) {
        return position < 0 || position >= visible.size() ? null : visible.get(position);
    }

    @Override public int getItemCount() { return visible.size(); }

    /** A type per preference class: its rows are alike. */
    @Override public int getItemViewType(int position) {
        Class<?> kind = getItem(position).getClass();
        for (int type = 0; type < rowTypes.size(); type++) if (rowTypes.get(type).getClass() == kind) return type;
        rowTypes.add(getItem(position));
        return rowTypes.size() - 1;
    }

    @Override public PreferenceViewHolder onCreateViewHolder(ViewGroup parent, int viewType) {
        return new PreferenceViewHolder(rowTypes.get(viewType).createRow(parent.getContext()));
    }

    @Override public void onBindViewHolder(PreferenceViewHolder holder, int position) {
        getItem(position).onBindViewHolder(holder);
    }

    @Override public void onPreferenceChange(Preference preference) {
        int index = visible.indexOf(preference);
        if (index != -1) notifyItemChanged(index, preference);
    }

    @Override public void onPreferenceHierarchyChange(Preference preference) { postSync(); }
    @Override public void onPreferenceVisibilityChange(Preference preference) { postSync(); }

    private void postSync() {
        if (syncPosted) return;
        syncPosted = true;
        MainThread.post(() -> {
            syncPosted = false;
            update();
        });
    }
}
