package android.content;

import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.res.Resources;
import java.io.File;

/** A context that hands everything to its base context, when it has one (a ContextThemeWrapper around the activity). */
public class ContextWrapper extends Context {
    private Context base;

    public ContextWrapper(Context base) {
        this.base = base;
    }

    protected void attachBaseContext(Context base) {
        this.base = base;
    }

    public Context getBaseContext() {
        return base;
    }

    @Override public Context getApplicationContext() { return base != null ? base.getApplicationContext() : super.getApplicationContext(); }
    @Override public SharedPreferences getSharedPreferences(String name, int mode) { return base != null ? base.getSharedPreferences(name, mode) : super.getSharedPreferences(name, mode); }
    @Override public String getPackageName() { return base != null ? base.getPackageName() : super.getPackageName(); }
    @Override public File getFilesDir() { return base != null ? base.getFilesDir() : super.getFilesDir(); }
    @Override public File getCacheDir() { return base != null ? base.getCacheDir() : super.getCacheDir(); }
    @Override public File getDir(String name, int mode) { return base != null ? base.getDir(name, mode) : super.getDir(name, mode); }
    @Override public Resources getResources() { return base != null ? base.getResources() : super.getResources(); }
    @Override public Resources.Theme getTheme() { return base != null ? base.getTheme() : super.getTheme(); }
    @Override public ClassLoader getClassLoader() { return base != null ? base.getClassLoader() : super.getClassLoader(); }
    @Override public PackageManager getPackageManager() { return base != null ? base.getPackageManager() : super.getPackageManager(); }
    @Override public ContentResolver getContentResolver() { return base != null ? base.getContentResolver() : super.getContentResolver(); }
    @Override public Object getSystemService(String name) { return base != null ? base.getSystemService(name) : super.getSystemService(name); }
    @Override public String getSystemServiceName(Class<?> serviceClass) { return base != null ? base.getSystemServiceName(serviceClass) : super.getSystemServiceName(serviceClass); }
    @Override public void startActivity(Intent intent) { if (base != null) base.startActivity(intent); else super.startActivity(intent); }
    @Override public ApplicationInfo getApplicationInfo() { return base != null ? base.getApplicationInfo() : super.getApplicationInfo(); }
}
