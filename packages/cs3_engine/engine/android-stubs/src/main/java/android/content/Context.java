package android.content;

import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.res.Resources;
import android.os.Bundle;
import android.os.Looper;
import android.view.LayoutInflater;
import android.view.inputmethod.InputMethodManager;
import dev.akash.cs3engine.stubs.FilePreferences;
import dev.akash.cs3engine.stubs.Platform;
import dev.akash.cs3engine.stubs.StubEnv;
import java.io.File;

/**
 * JVM stand-in for android.content.Context: working preferences and directories, the platform's services
 * (starts, the clipboard), the rest inert.
 */
public class Context {
    public static final int MODE_PRIVATE = 0;
    public static final String ACTIVITY_SERVICE = "activity";
    public static final String CLIPBOARD_SERVICE = "clipboard";
    public static final String INPUT_METHOD_SERVICE = "input_method";
    public static final String LAYOUT_INFLATER_SERVICE = "layout_inflater";
    public static final String WINDOW_SERVICE = "window";

    private static final ContentResolver CONTENT_RESOLVER = new ContentResolver();
    private static final android.app.ActivityManager ACTIVITY_MANAGER = new android.app.ActivityManager();
    private static final ClipboardManager CLIPBOARD = new ClipboardManager();
    private static final InputMethodManager INPUT_METHOD = new InputMethodManager();
    private static final PackageManager PACKAGES = new PackageManager();

    public Context getApplicationContext() { return this; }
    public SharedPreferences getSharedPreferences(String name, int mode) { return FilePreferences.get(name); }
    public String getPackageName() { return StubEnv.packageName(); }
    public File getFilesDir() { return StubEnv.dir("files"); }
    public File getCacheDir() { return StubEnv.dir("cache"); }
    public File getDir(String name, int mode) { return StubEnv.dir("app_" + name); }

    // Android's other folders, all in the engine's own: a null here would put an extension's file relative to
    // the engine's working directory.
    public File getDataDir() { return StubEnv.root(); }
    public File getNoBackupFilesDir() { return StubEnv.dir("no_backup"); }
    public File getCodeCacheDir() { return StubEnv.dir("code_cache"); }
    public File getObbDir() { return StubEnv.dir("obb"); }
    public File getExternalCacheDir() { return StubEnv.dir("external/cache"); }
    public File[] getExternalCacheDirs() { return new File[] {getExternalCacheDir()}; }
    public File getDatabasePath(String name) { return new File(StubEnv.dir("databases"), name); }
    public File getFileStreamPath(String name) { return new File(getFilesDir(), name); }

    /** The app's folder on shared storage, or [type]'s in it ("Download"): the engine's own here. */
    public File getExternalFilesDir(String type) {
        File files = StubEnv.dir("external/files");
        if (type == null) return files;
        File dir = new File(files, type);
        dir.mkdirs();
        return dir;
    }

    public File[] getExternalFilesDirs(String type) { return new File[] {getExternalFilesDir(type)}; }
    public Resources getResources() { return Resources.getSystem(); }

    private Resources.Theme theme;

    /** The context's theme, made from its resources the first time it's asked for (CloudStream's UIHelper reads it). */
    public Resources.Theme getTheme() {
        if (theme == null) theme = getResources().newTheme();
        return theme;
    }

    public ClassLoader getClassLoader() { return Context.class.getClassLoader(); }
    public Looper getMainLooper() { return Looper.getMainLooper(); }
    public PackageManager getPackageManager() { return PACKAGES; }
    public ContentResolver getContentResolver() { return CONTENT_RESOLVER; }
    /**
     * The app's strings: Android's common ones (OK, Cancel…). Any other id reads as empty, as it did before:
     * an extension that asks the app for its own strings mustn't fail to load over it. As on Android, these
     * are final and read {@link #getResources()}, so a wrapper that gives its own resources gives their strings.
     */
    public final String getString(int resId) {
        try {
            return getResources().getString(resId);
        } catch (Resources.NotFoundException e) {
            return "";
        }
    }

    public final String getString(int resId, Object... formatArgs) {
        try {
            return getResources().getString(resId, formatArgs);
        } catch (Resources.NotFoundException e) {
            return "";
        }
    }

    public final CharSequence getText(int resId) { return getString(resId); }

    public Object getSystemService(String name) {
        if (name == null) return null;
        switch (name) {
            case ACTIVITY_SERVICE: return ACTIVITY_MANAGER;
            case CLIPBOARD_SERVICE: return CLIPBOARD;
            case INPUT_METHOD_SERVICE: return INPUT_METHOD;
            case LAYOUT_INFLATER_SERVICE: return LayoutInflater.from(this);
            default: return null;
        }
    }

    public final <T> T getSystemService(Class<T> serviceClass) {
        String name = getSystemServiceName(serviceClass);
        return name == null ? null : serviceClass.cast(getSystemService(name));
    }

    public String getSystemServiceName(Class<?> serviceClass) {
        if (serviceClass == ClipboardManager.class) return CLIPBOARD_SERVICE;
        if (serviceClass == InputMethodManager.class) return INPUT_METHOD_SERVICE;
        if (serviceClass == android.app.ActivityManager.class) return ACTIVITY_SERVICE;
        if (serviceClass == LayoutInflater.class) return LAYOUT_INFLATER_SERVICE;
        return null;
    }

    /** A link, a share, the app's restart: the platform decides (a restart throws, and never reaches the exit after it). */
    public void startActivity(Intent intent) { Platform.host().startActivity(this, intent); }
    public void startActivity(Intent intent, Bundle options) { startActivity(intent); }

    public ApplicationInfo getApplicationInfo() {
        ApplicationInfo info = new ApplicationInfo();
        info.packageName = getPackageName();
        info.nonLocalizedLabel = StubEnv.appLabel();
        info.dataDir = StubEnv.root().getAbsolutePath();
        return info;
    }
}
