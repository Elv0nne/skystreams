package androidx.preference;

import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.res.TypedArray;
import android.graphics.drawable.Drawable;
import android.os.Bundle;
import android.text.TextUtils;
import android.util.AttributeSet;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.RelativeLayout;
import android.widget.TextView;
import java.util.Set;

/**
 * A stand-in preference: its words, icon and state, its value kept in its manager's shared preferences or
 * data store. Its row is made and bound as androidx.preference's preference_material layout arranges it, so
 * a screen reads as Android's does.
 */
public class Preference implements Comparable<Preference> {
    public static final int DEFAULT_ORDER = Integer.MAX_VALUE;

    /** androidx.preference's not_set, in English: the engine has no other translations of the library's words. */
    static final String NOT_SET = "Not set";

    public interface OnPreferenceChangeListener {
        boolean onPreferenceChange(Preference preference, Object newValue);
    }

    public interface OnPreferenceClickListener {
        boolean onPreferenceClick(Preference preference);
    }

    public interface SummaryProvider<T extends Preference> {
        CharSequence provideSummary(T preference);
    }

    /** What its rows' adapter hears. */
    interface OnPreferenceChangeInternalListener {
        void onPreferenceChange(Preference preference);

        void onPreferenceHierarchyChange(Preference preference);

        void onPreferenceVisibilityChange(Preference preference);
    }

    private final Context context;
    private final View.OnClickListener rowClick = this::performClick;
    private PreferenceManager preferenceManager;
    private PreferenceDataStore dataStore;
    private PreferenceGroup parent;
    private OnPreferenceChangeInternalListener internalListener;
    private OnPreferenceChangeListener changeListener;
    private OnPreferenceClickListener clickListener;
    private SummaryProvider summaryProvider;
    private int order = DEFAULT_ORDER;
    private CharSequence title;
    private CharSequence summary;
    private Drawable icon;
    private int iconResId;
    private String key;
    private Intent intent;
    private String fragment;
    private Bundle extras;
    private Object defaultValue;
    private boolean enabled = true;
    private boolean selectable = true;
    private boolean persistent = true;
    private boolean visible = true;
    private boolean shouldDisableView = true;

    public Preference(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        this.context = context;
    }

    public Preference(Context context, AttributeSet attrs, int defStyleAttr) {
        this(context, attrs, defStyleAttr, 0);
    }

    public Preference(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public Preference(Context context) {
        this(context, null);
    }

    protected Object onGetDefaultValue(TypedArray a, int index) { return null; }
    public Context getContext() { return context; }
    public void setIntent(Intent intent) { this.intent = intent; }
    public Intent getIntent() { return intent; }
    public void setFragment(String fragment) { this.fragment = fragment; }
    public String getFragment() { return fragment; }
    public void setPreferenceDataStore(PreferenceDataStore dataStore) { this.dataStore = dataStore; }

    public PreferenceDataStore getPreferenceDataStore() {
        if (dataStore != null) return dataStore;
        return preferenceManager != null ? preferenceManager.getPreferenceDataStore() : null;
    }

    public Bundle getExtras() {
        if (extras == null) extras = new Bundle();
        return extras;
    }

    public Bundle peekExtras() { return extras; }

    public void setOrder(int order) {
        if (order == this.order) return;
        this.order = order;
        notifyHierarchyChanged();
    }

    public int getOrder() { return order; }

    public void setTitle(CharSequence title) {
        if (TextUtils.equals(title, this.title)) return;
        this.title = title;
        notifyChanged();
    }

    public void setTitle(int titleResId) { setTitle(context.getString(titleResId)); }
    public CharSequence getTitle() { return title; }

    public void setIcon(Drawable icon) {
        if (this.icon == icon && iconResId == 0) return;
        this.icon = icon;
        iconResId = 0;
        notifyChanged();
    }

    /** An icon from the app's drawables: the stand-ins draw nothing, so it's only shown as there. */
    public void setIcon(int iconResId) {
        if (this.iconResId == iconResId) return;
        this.iconResId = iconResId;
        icon = null;
        notifyChanged();
    }

    public Drawable getIcon() { return icon; }

    @SuppressWarnings("unchecked")
    public CharSequence getSummary() {
        if (summaryProvider != null) return summaryProvider.provideSummary(this);
        return summary;
    }

    public void setSummary(CharSequence summary) {
        if (summaryProvider != null) throw new IllegalStateException("Preference already has a SummaryProvider set.");
        if (TextUtils.equals(this.summary, summary)) return;
        this.summary = summary;
        notifyChanged();
    }

    public void setSummary(int summaryResId) { setSummary(context.getString(summaryResId)); }

    public final void setSummaryProvider(SummaryProvider summaryProvider) {
        this.summaryProvider = summaryProvider;
        notifyChanged();
    }

    public final SummaryProvider getSummaryProvider() { return summaryProvider; }

    public void setEnabled(boolean enabled) {
        if (this.enabled == enabled) return;
        this.enabled = enabled;
        notifyChanged();
    }

    public boolean isEnabled() { return enabled; }

    public void setSelectable(boolean selectable) {
        if (this.selectable == selectable) return;
        this.selectable = selectable;
        notifyChanged();
    }

    public boolean isSelectable() { return selectable; }

    public void setShouldDisableView(boolean shouldDisableView) {
        if (this.shouldDisableView == shouldDisableView) return;
        this.shouldDisableView = shouldDisableView;
        notifyChanged();
    }

    public boolean getShouldDisableView() { return shouldDisableView; }

    public final void setVisible(boolean visible) {
        if (this.visible == visible) return;
        this.visible = visible;
        if (internalListener != null) internalListener.onPreferenceVisibilityChange(this);
    }

    public final boolean isVisible() { return visible; }

    public final boolean isShown() {
        if (!visible || preferenceManager == null) return false;
        if (this == preferenceManager.getPreferenceScreen()) return true;
        return parent != null && parent.isShown();
    }

    protected void onClick() {}
    public void setKey(String key) { this.key = key; }
    public String getKey() { return key; }
    public boolean hasKey() { return !TextUtils.isEmpty(key); }
    public boolean isPersistent() { return persistent; }
    protected boolean shouldPersist() { return preferenceManager != null && isPersistent() && hasKey(); }
    public void setPersistent(boolean persistent) { this.persistent = persistent; }

    public boolean callChangeListener(Object newValue) {
        return changeListener == null || changeListener.onPreferenceChange(this, newValue);
    }

    public void setOnPreferenceChangeListener(OnPreferenceChangeListener listener) { changeListener = listener; }
    public OnPreferenceChangeListener getOnPreferenceChangeListener() { return changeListener; }
    public void setOnPreferenceClickListener(OnPreferenceClickListener listener) { clickListener = listener; }
    public OnPreferenceClickListener getOnPreferenceClickListener() { return clickListener; }

    protected void performClick(View view) {
        performClick();
    }

    /** A tap, in Android's order: its own onClick, its click listener, its fragment, then its intent. */
    public void performClick() {
        if (!isEnabled() || !isSelectable()) return;
        onClick();
        if (clickListener != null && clickListener.onPreferenceClick(this)) return;
        if (preferenceManager != null) {
            PreferenceManager.OnPreferenceTreeClickListener listener = preferenceManager.getOnPreferenceTreeClickListener();
            if (listener != null && listener.onPreferenceTreeClick(this)) return;
        }
        if (intent != null) context.startActivity(intent);
    }

    public SharedPreferences getSharedPreferences() {
        if (preferenceManager == null || getPreferenceDataStore() != null) return null;
        return preferenceManager.getSharedPreferences();
    }

    /** By order, then by title, as Android's. */
    @Override public int compareTo(Preference another) {
        if (order != another.order) return Integer.compare(order, another.order);
        if (title == another.title) return 0;
        if (title == null) return 1;
        if (another.title == null) return -1;
        return title.toString().compareToIgnoreCase(another.title.toString());
    }

    protected void notifyChanged() {
        if (internalListener != null) internalListener.onPreferenceChange(this);
    }

    protected void notifyHierarchyChanged() {
        if (internalListener != null) internalListener.onPreferenceHierarchyChange(this);
    }

    public PreferenceManager getPreferenceManager() { return preferenceManager; }

    protected void onAttachedToHierarchy(PreferenceManager preferenceManager) {
        this.preferenceManager = preferenceManager;
        dispatchSetInitialValue();
    }

    protected void onAttachedToHierarchy(PreferenceManager preferenceManager, long id) {
        onAttachedToHierarchy(preferenceManager);
    }

    public void onAttached() {}
    public void onDetached() {}
    public PreferenceGroup getParent() { return parent; }
    protected void onPrepareForRemoval() {}
    public void setDefaultValue(Object defaultValue) { this.defaultValue = defaultValue; }

    /** Android's: the data store's or the saved value, else the default (saved by its kind's setter). */
    private void dispatchSetInitialValue() {
        if (getPreferenceDataStore() != null) {
            onSetInitialValue(true, defaultValue);
            return;
        }
        if (!shouldPersist() || !getSharedPreferences().contains(key)) {
            if (defaultValue != null) onSetInitialValue(false, defaultValue);
        } else {
            onSetInitialValue(true, null);
        }
    }

    @Deprecated
    protected void onSetInitialValue(boolean restorePersistedValue, Object defaultValue) {
        onSetInitialValue(defaultValue);
    }

    protected void onSetInitialValue(Object defaultValue) {}

    private SharedPreferences.Editor editor() { return preferenceManager.getSharedPreferences().edit(); }

    protected boolean persistString(String value) {
        if (!shouldPersist()) return false;
        if (TextUtils.equals(value, getPersistedString(null))) return true;
        PreferenceDataStore store = getPreferenceDataStore();
        if (store != null) store.putString(key, value);
        else editor().putString(key, value).apply();
        return true;
    }

    protected String getPersistedString(String defaultReturnValue) {
        if (!shouldPersist()) return defaultReturnValue;
        PreferenceDataStore store = getPreferenceDataStore();
        return store != null ? store.getString(key, defaultReturnValue) : preferenceManager.getSharedPreferences().getString(key, defaultReturnValue);
    }

    public boolean persistStringSet(Set<String> values) {
        if (!shouldPersist()) return false;
        if (values != null && values.equals(getPersistedStringSet(null))) return true;
        PreferenceDataStore store = getPreferenceDataStore();
        if (store != null) store.putStringSet(key, values);
        else editor().putStringSet(key, values).apply();
        return true;
    }

    public Set<String> getPersistedStringSet(Set<String> defaultReturnValue) {
        if (!shouldPersist()) return defaultReturnValue;
        PreferenceDataStore store = getPreferenceDataStore();
        return store != null ? store.getStringSet(key, defaultReturnValue) : preferenceManager.getSharedPreferences().getStringSet(key, defaultReturnValue);
    }

    protected boolean persistInt(int value) {
        if (!shouldPersist()) return false;
        if (value == getPersistedInt(~value)) return true;
        PreferenceDataStore store = getPreferenceDataStore();
        if (store != null) store.putInt(key, value);
        else editor().putInt(key, value).apply();
        return true;
    }

    protected int getPersistedInt(int defaultReturnValue) {
        if (!shouldPersist()) return defaultReturnValue;
        PreferenceDataStore store = getPreferenceDataStore();
        return store != null ? store.getInt(key, defaultReturnValue) : preferenceManager.getSharedPreferences().getInt(key, defaultReturnValue);
    }

    protected boolean persistFloat(float value) {
        if (!shouldPersist()) return false;
        if (value == getPersistedFloat(Float.NaN)) return true;
        PreferenceDataStore store = getPreferenceDataStore();
        if (store != null) store.putFloat(key, value);
        else editor().putFloat(key, value).apply();
        return true;
    }

    protected float getPersistedFloat(float defaultReturnValue) {
        if (!shouldPersist()) return defaultReturnValue;
        PreferenceDataStore store = getPreferenceDataStore();
        return store != null ? store.getFloat(key, defaultReturnValue) : preferenceManager.getSharedPreferences().getFloat(key, defaultReturnValue);
    }

    protected boolean persistLong(long value) {
        if (!shouldPersist()) return false;
        if (value == getPersistedLong(~value)) return true;
        PreferenceDataStore store = getPreferenceDataStore();
        if (store != null) store.putLong(key, value);
        else editor().putLong(key, value).apply();
        return true;
    }

    protected long getPersistedLong(long defaultReturnValue) {
        if (!shouldPersist()) return defaultReturnValue;
        PreferenceDataStore store = getPreferenceDataStore();
        return store != null ? store.getLong(key, defaultReturnValue) : preferenceManager.getSharedPreferences().getLong(key, defaultReturnValue);
    }

    protected boolean persistBoolean(boolean value) {
        if (!shouldPersist()) return false;
        if (value == getPersistedBoolean(!value)) return true;
        PreferenceDataStore store = getPreferenceDataStore();
        if (store != null) store.putBoolean(key, value);
        else editor().putBoolean(key, value).apply();
        return true;
    }

    protected boolean getPersistedBoolean(boolean defaultReturnValue) {
        if (!shouldPersist()) return defaultReturnValue;
        PreferenceDataStore store = getPreferenceDataStore();
        return store != null ? store.getBoolean(key, defaultReturnValue) : preferenceManager.getSharedPreferences().getBoolean(key, defaultReturnValue);
    }

    /** Its title and summary, as Android's. */
    @Override public String toString() {
        StringBuilder out = new StringBuilder();
        if (!TextUtils.isEmpty(title)) out.append(title).append(' ');
        CharSequence shown = getSummary();
        if (!TextUtils.isEmpty(shown)) out.append(shown).append(' ');
        if (out.length() > 0) out.setLength(out.length() - 1);
        return out.toString();
    }

    /** Fills its row: the tap, title and summary (hidden when empty), the icon, and the enabled state, as Android's. */
    public void onBindViewHolder(PreferenceViewHolder holder) {
        View itemView = holder.itemView;
        itemView.setOnClickListener(rowClick);
        bindText(holder.findViewById(android.R.id.title), getTitle());
        bindText(holder.findViewById(android.R.id.summary), getSummary());
        boolean hasIcon = icon != null || iconResId != 0;
        View iconView = holder.findViewById(android.R.id.icon);
        if (iconView instanceof ImageView && icon != null) ((ImageView) iconView).setImageDrawable(icon);
        if (iconView != null) iconView.setVisibility(hasIcon ? View.VISIBLE : View.GONE);
        View iconFrame = holder.findViewById(R.id.icon_frame);
        if (iconFrame != null) iconFrame.setVisibility(hasIcon ? View.VISIBLE : View.GONE);
        setEnabledStateOnViews(itemView, !shouldDisableView || isEnabled());
        itemView.setFocusable(isSelectable());
        itemView.setClickable(isSelectable());
    }

    private static void bindText(View view, CharSequence text) {
        if (!(view instanceof TextView)) return;
        if (TextUtils.isEmpty(text)) {
            view.setVisibility(View.GONE);
            return;
        }
        ((TextView) view).setText(text);
        view.setVisibility(View.VISIBLE);
    }

    static void setEnabledStateOnViews(View view, boolean enabled) {
        view.setEnabled(enabled);
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) view;
            for (int i = 0; i < group.getChildCount(); i++) setEnabledStateOnViews(group.getChildAt(i), enabled);
        }
    }

    // Rows: the views androidx.preference's layouts give, made in code.

    void assignParent(PreferenceGroup parent) { this.parent = parent; }
    void setOnPreferenceChangeInternalListener(OnPreferenceChangeInternalListener listener) { internalListener = listener; }

    /** Its row, as preference_material arranges one: the icon's frame, the title over the summary (weight 1), its widget's frame. */
    View createRow(Context context) {
        LinearLayout row = new LinearLayout(context);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.addView(iconFrame(context));
        row.addView(titleAndSummary(context), new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        LinearLayout widgetFrame = new LinearLayout(context);
        widgetFrame.setId(android.R.id.widget_frame);
        widgetFrame.setOrientation(LinearLayout.VERTICAL);
        View widget = onCreateWidget(context);
        if (widget != null) widgetFrame.addView(widget);
        else widgetFrame.setVisibility(View.GONE);
        row.addView(widgetFrame);
        return row;
    }

    /** The widget its row's frame holds (a switch); none for a plain preference. */
    View onCreateWidget(Context context) { return null; }

    static LinearLayout iconFrame(Context context) {
        LinearLayout frame = new LinearLayout(context);
        frame.setOrientation(LinearLayout.HORIZONTAL);
        frame.setId(R.id.icon_frame);
        ImageView icon = new ImageView(context);
        icon.setId(android.R.id.icon);
        frame.addView(icon);
        return frame;
    }

    static RelativeLayout titleAndSummary(Context context) {
        RelativeLayout words = new RelativeLayout(context);
        TextView title = new TextView(context);
        title.setId(android.R.id.title);
        TextView summary = new TextView(context);
        summary.setId(android.R.id.summary);
        words.addView(title);
        words.addView(summary);
        return words;
    }
}
