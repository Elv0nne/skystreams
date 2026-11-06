package androidx.preference;

import android.content.Context;
import android.text.TextUtils;
import android.util.AttributeSet;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/** Preferences held in order: by order, then title; as added unless told otherwise. */
public abstract class PreferenceGroup extends Preference {
    private final List<Preference> preferences = new ArrayList<>();
    private boolean orderingAsAdded = true;
    private int currentOrder;
    private boolean attached;

    public PreferenceGroup(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
    }

    public PreferenceGroup(Context context, AttributeSet attrs, int defStyleAttr) {
        this(context, attrs, defStyleAttr, 0);
    }

    public PreferenceGroup(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public void setOrderingAsAdded(boolean orderingAsAdded) { this.orderingAsAdded = orderingAsAdded; }
    public boolean isOrderingAsAdded() { return orderingAsAdded; }
    public void addItemFromInflater(Preference preference) { addPreference(preference); }
    public int getPreferenceCount() { return preferences.size(); }
    public Preference getPreference(int index) { return preferences.get(index); }

    /**
     * Adds [preference] in its place, and attaches it: it takes its saved value or default. A group must be in
     * a screen first; Android fails the same way.
     */
    public boolean addPreference(Preference preference) {
        if (preferences.contains(preference)) return true;
        if (preference.getOrder() == DEFAULT_ORDER) {
            if (orderingAsAdded) preference.setOrder(currentOrder++);
            if (preference instanceof PreferenceGroup) ((PreferenceGroup) preference).setOrderingAsAdded(orderingAsAdded);
        }
        int index = Collections.binarySearch(preferences, preference);
        if (index < 0) index = -index - 1;
        if (!onPrepareAddPreference(preference)) return false;
        preferences.add(index, preference);
        PreferenceManager manager = getPreferenceManager();
        preference.onAttachedToHierarchy(manager, manager.getNextId());
        preference.assignParent(this);
        if (attached) preference.onAttached();
        notifyHierarchyChanged();
        return true;
    }

    public boolean removePreference(Preference preference) {
        boolean removed = removePreferenceInt(preference);
        notifyHierarchyChanged();
        return removed;
    }

    private boolean removePreferenceInt(Preference preference) {
        preference.onPrepareForRemoval();
        if (preference.getParent() == this) preference.assignParent(null);
        boolean removed = preferences.remove(preference);
        if (removed) preference.onDetached();
        return removed;
    }

    public boolean removePreferenceRecursively(CharSequence key) {
        Preference preference = findPreference(key);
        return preference != null && preference.getParent() != null && preference.getParent().removePreference(preference);
    }

    public void removeAll() {
        for (int i = preferences.size() - 1; i >= 0; i--) removePreferenceInt(preferences.get(0));
        notifyHierarchyChanged();
    }

    protected boolean onPrepareAddPreference(Preference preference) { return true; }

    @SuppressWarnings("unchecked")
    public <T extends Preference> T findPreference(CharSequence key) {
        if (key == null) throw new IllegalArgumentException("Key cannot be null");
        if (TextUtils.equals(getKey(), key)) return (T) this;
        for (Preference preference : preferences) {
            if (TextUtils.equals(preference.getKey(), key)) return (T) preference;
            if (preference instanceof PreferenceGroup) {
                T found = ((PreferenceGroup) preference).findPreference(key);
                if (found != null) return found;
            }
        }
        return null;
    }

    /** A category's preferences show among its own; a screen's open a screen of their own. */
    protected boolean isOnSameScreenAsChildren() { return true; }

    public boolean isAttached() { return attached; }

    @Override public void onAttached() {
        super.onAttached();
        attached = true;
        for (Preference preference : preferences) preference.onAttached();
    }

    @Override public void onDetached() {
        super.onDetached();
        attached = false;
        for (Preference preference : preferences) preference.onDetached();
    }
}
