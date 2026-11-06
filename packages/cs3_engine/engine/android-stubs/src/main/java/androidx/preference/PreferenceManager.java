package androidx.preference;

import android.content.Context;
import android.content.SharedPreferences;

/** A screen's preferences and where their values go: shared preferences by name, or a data store. */
public class PreferenceManager {
    public static final String KEY_HAS_SET_DEFAULT_VALUES = "_has_set_default_values";

    public interface OnPreferenceTreeClickListener {
        boolean onPreferenceTreeClick(Preference preference);
    }

    public interface OnDisplayPreferenceDialogListener {
        void onDisplayPreferenceDialog(Preference preference);
    }

    private final Context context;
    private long nextId;
    private String sharedPreferencesName;
    private int sharedPreferencesMode = Context.MODE_PRIVATE;
    private SharedPreferences sharedPreferences;
    private PreferenceDataStore dataStore;
    private PreferenceScreen screen;
    private OnPreferenceTreeClickListener treeClickListener;
    private OnDisplayPreferenceDialogListener dialogListener;

    public PreferenceManager(Context context) {
        this.context = context;
        sharedPreferencesName = getDefaultSharedPreferencesName(context);
    }

    public static SharedPreferences getDefaultSharedPreferences(Context context) {
        return context.getSharedPreferences(getDefaultSharedPreferencesName(context), Context.MODE_PRIVATE);
    }

    public static String getDefaultSharedPreferencesName(Context context) {
        return context.getPackageName() + "_preferences";
    }

    public PreferenceScreen createPreferenceScreen(Context context) {
        PreferenceScreen created = new PreferenceScreen(context, null);
        created.onAttachedToHierarchy(this);
        return created;
    }

    synchronized long getNextId() { return nextId++; }
    public String getSharedPreferencesName() { return sharedPreferencesName; }

    public void setSharedPreferencesName(String sharedPreferencesName) {
        this.sharedPreferencesName = sharedPreferencesName;
        sharedPreferences = null;
    }

    public int getSharedPreferencesMode() { return sharedPreferencesMode; }

    public void setSharedPreferencesMode(int sharedPreferencesMode) {
        this.sharedPreferencesMode = sharedPreferencesMode;
        sharedPreferences = null;
    }

    public void setPreferenceDataStore(PreferenceDataStore dataStore) { this.dataStore = dataStore; }
    public PreferenceDataStore getPreferenceDataStore() { return dataStore; }

    /** Null while a data store holds the values, as Android's. */
    public SharedPreferences getSharedPreferences() {
        if (dataStore != null) return null;
        if (sharedPreferences == null) sharedPreferences = context.getSharedPreferences(sharedPreferencesName, sharedPreferencesMode);
        return sharedPreferences;
    }

    public PreferenceScreen getPreferenceScreen() { return screen; }

    public boolean setPreferences(PreferenceScreen preferenceScreen) {
        if (preferenceScreen == screen) return false;
        if (screen != null) screen.onDetached();
        screen = preferenceScreen;
        return true;
    }

    public <T extends Preference> T findPreference(CharSequence key) {
        return screen == null ? null : screen.findPreference(key);
    }

    public Context getContext() { return context; }
    public OnDisplayPreferenceDialogListener getOnDisplayPreferenceDialogListener() { return dialogListener; }
    public void setOnDisplayPreferenceDialogListener(OnDisplayPreferenceDialogListener listener) { dialogListener = listener; }

    public void showDialog(Preference preference) {
        if (dialogListener != null) dialogListener.onDisplayPreferenceDialog(preference);
    }

    public void setOnPreferenceTreeClickListener(OnPreferenceTreeClickListener listener) { treeClickListener = listener; }
    public OnPreferenceTreeClickListener getOnPreferenceTreeClickListener() { return treeClickListener; }
}
