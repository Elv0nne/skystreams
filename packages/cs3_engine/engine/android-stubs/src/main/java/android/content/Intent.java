package android.content;

import android.net.Uri;
import android.os.Bundle;
import android.os.Parcelable;
import java.io.Serializable;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.Set;

/** An intent, as extensions build them to open links, share text and restart the app; starts go to the platform. */
public class Intent implements Parcelable, Cloneable {
    public static final String ACTION_MAIN = "android.intent.action.MAIN";
    public static final String ACTION_VIEW = "android.intent.action.VIEW";
    public static final String ACTION_SEND = "android.intent.action.SEND";
    public static final String ACTION_SENDTO = "android.intent.action.SENDTO";
    public static final String ACTION_CHOOSER = "android.intent.action.CHOOSER";
    public static final String ACTION_GET_CONTENT = "android.intent.action.GET_CONTENT";
    public static final String ACTION_OPEN_DOCUMENT = "android.intent.action.OPEN_DOCUMENT";
    public static final String ACTION_CREATE_DOCUMENT = "android.intent.action.CREATE_DOCUMENT";
    public static final String CATEGORY_DEFAULT = "android.intent.category.DEFAULT";
    public static final String CATEGORY_LAUNCHER = "android.intent.category.LAUNCHER";
    public static final String CATEGORY_BROWSABLE = "android.intent.category.BROWSABLE";
    public static final String CATEGORY_OPENABLE = "android.intent.category.OPENABLE";
    public static final String EXTRA_TEXT = "android.intent.extra.TEXT";
    public static final String EXTRA_SUBJECT = "android.intent.extra.SUBJECT";
    public static final String EXTRA_TITLE = "android.intent.extra.TITLE";
    public static final String EXTRA_STREAM = "android.intent.extra.STREAM";
    public static final String EXTRA_INTENT = "android.intent.extra.INTENT";
    public static final int FLAG_GRANT_READ_URI_PERMISSION = 0x00000001;
    public static final int FLAG_GRANT_WRITE_URI_PERMISSION = 0x00000002;
    public static final int FLAG_ACTIVITY_CLEAR_TASK = 0x00008000;
    public static final int FLAG_ACTIVITY_CLEAR_TOP = 0x04000000;
    public static final int FLAG_ACTIVITY_NEW_TASK = 0x10000000;

    private String action;
    private Uri data;
    private String type;
    private String packageName;
    private ComponentName component;
    private int flags;
    private Set<String> categories;
    private Bundle extras;

    public Intent() {}

    public Intent(Intent o) {
        if (o == null) return;
        action = o.action;
        data = o.data;
        type = o.type;
        packageName = o.packageName;
        component = o.component;
        flags = o.flags;
        if (o.categories != null) categories = new LinkedHashSet<>(o.categories);
        if (o.extras != null) extras = new Bundle(o.extras);
    }

    public Intent(String action) {
        this.action = action;
    }

    public Intent(String action, Uri uri) {
        this.action = action;
        this.data = uri;
    }

    public Intent(Context packageContext, Class<?> cls) {
        this.component = new ComponentName(packageContext, cls);
    }

    public Intent(String action, Uri uri, Context packageContext, Class<?> cls) {
        this(action, uri);
        this.component = new ComponentName(packageContext, cls);
    }

    public static Intent makeMainActivity(ComponentName mainActivity) {
        Intent intent = new Intent(ACTION_MAIN);
        intent.setComponent(mainActivity);
        intent.addCategory(CATEGORY_LAUNCHER);
        return intent;
    }

    /** What 44 of the 79 settings screens start before they exit: the platform stops it (a restart). */
    public static Intent makeRestartActivityTask(ComponentName mainActivity) {
        Intent intent = makeMainActivity(mainActivity);
        intent.addFlags(FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_CLEAR_TASK);
        return intent;
    }

    public static Intent createChooser(Intent target, CharSequence title) {
        Intent intent = new Intent(ACTION_CHOOSER);
        intent.putExtra(EXTRA_INTENT, target);
        if (title != null) intent.putExtra(EXTRA_TITLE, title);
        return intent;
    }

    private Bundle extras() {
        if (extras == null) extras = new Bundle();
        return extras;
    }

    public String getAction() { return action; }
    public Intent setAction(String action) { this.action = action; return this; }
    public Uri getData() { return data; }
    public String getDataString() { return data == null ? null : data.toString(); }
    public Intent setData(Uri data) { this.data = data; this.type = null; return this; }
    public String getType() { return type; }
    public Intent setType(String type) { this.type = type; this.data = null; return this; }
    public Intent setDataAndType(Uri data, String type) { this.data = data; this.type = type; return this; }
    public String getScheme() { return data == null ? null : data.getScheme(); }
    public String getPackage() { return packageName; }
    public Intent setPackage(String packageName) { this.packageName = packageName; return this; }
    public ComponentName getComponent() { return component; }
    public Intent setComponent(ComponentName component) { this.component = component; return this; }
    public Intent setClass(Context packageContext, Class<?> cls) { component = new ComponentName(packageContext, cls); return this; }
    public Intent setClassName(Context packageContext, String className) { component = new ComponentName(packageContext, className); return this; }
    public Intent setClassName(String packageName, String className) { component = new ComponentName(packageName, className); return this; }
    public int getFlags() { return flags; }
    public Intent setFlags(int flags) { this.flags = flags; return this; }
    public Intent addFlags(int flags) { this.flags |= flags; return this; }
    public void removeFlags(int flags) { this.flags &= ~flags; }

    public Intent addCategory(String category) {
        if (categories == null) categories = new LinkedHashSet<>();
        categories.add(category);
        return this;
    }

    public void removeCategory(String category) { if (categories != null) categories.remove(category); }
    public boolean hasCategory(String category) { return categories != null && categories.contains(category); }
    public Set<String> getCategories() { return categories; }

    public Intent putExtra(String name, boolean value) { extras().putBoolean(name, value); return this; }
    public Intent putExtra(String name, int value) { extras().putInt(name, value); return this; }
    public Intent putExtra(String name, long value) { extras().putLong(name, value); return this; }
    public Intent putExtra(String name, float value) { extras().putFloat(name, value); return this; }
    public Intent putExtra(String name, double value) { extras().putDouble(name, value); return this; }
    public Intent putExtra(String name, String value) { extras().putString(name, value); return this; }
    public Intent putExtra(String name, CharSequence value) { extras().putCharSequence(name, value); return this; }
    public Intent putExtra(String name, Parcelable value) { extras().putParcelable(name, value); return this; }
    public Intent putExtra(String name, Serializable value) { extras().putSerializable(name, value); return this; }
    public Intent putExtra(String name, String[] value) { extras().putStringArray(name, value); return this; }
    public Intent putExtra(String name, int[] value) { extras().putIntArray(name, value); return this; }
    public Intent putExtra(String name, Bundle value) { extras().putBundle(name, value); return this; }
    public Intent putStringArrayListExtra(String name, ArrayList<String> value) { extras().putStringArrayList(name, value); return this; }
    public Intent putExtras(Bundle extras) { extras().putAll(extras); return this; }
    public Intent replaceExtras(Bundle extras) { this.extras = extras == null ? null : new Bundle(extras); return this; }
    public void removeExtra(String name) { if (extras != null) extras.remove(name); }
    public boolean hasExtra(String name) { return extras != null && extras.containsKey(name); }
    public Bundle getExtras() { return extras == null ? null : new Bundle(extras); }

    public boolean getBooleanExtra(String name, boolean defaultValue) { return extras == null ? defaultValue : extras.getBoolean(name, defaultValue); }
    public int getIntExtra(String name, int defaultValue) { return extras == null ? defaultValue : extras.getInt(name, defaultValue); }
    public long getLongExtra(String name, long defaultValue) { return extras == null ? defaultValue : extras.getLong(name, defaultValue); }
    public float getFloatExtra(String name, float defaultValue) { return extras == null ? defaultValue : extras.getFloat(name, defaultValue); }
    public double getDoubleExtra(String name, double defaultValue) { return extras == null ? defaultValue : extras.getDouble(name, defaultValue); }
    public String getStringExtra(String name) { return extras == null ? null : extras.getString(name); }
    public CharSequence getCharSequenceExtra(String name) { return extras == null ? null : extras.getCharSequence(name); }
    public <T extends Parcelable> T getParcelableExtra(String name) { return extras == null ? null : extras.getParcelable(name); }
    public <T> T getParcelableExtra(String name, Class<T> clazz) { return extras == null ? null : extras.getParcelable(name, clazz); }
    public Serializable getSerializableExtra(String name) { return extras == null ? null : extras.getSerializable(name); }
    public String[] getStringArrayExtra(String name) { return extras == null ? null : extras.getStringArray(name); }
    public ArrayList<String> getStringArrayListExtra(String name) { return extras == null ? null : extras.getStringArrayList(name); }
    public Bundle getBundleExtra(String name) { return extras == null ? null : extras.getBundle(name); }

    @Override public Object clone() { return new Intent(this); }
    @Override public int describeContents() { return 0; }

    @Override public String toString() {
        return "Intent { act=" + action + (data == null ? "" : " dat=" + data) + (component == null ? "" : " cmp=" + component.flattenToShortString())
            + (flags == 0 ? "" : " flg=0x" + Integer.toHexString(flags)) + " }";
    }
}
