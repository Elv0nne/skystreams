package android.content.pm;

import android.content.Intent;
import dev.akash.cs3engine.stubs.StubEnv;
import java.util.ArrayList;
import java.util.List;

/**
 * The installed packages: the engine's own, as CloudStream's app. Its launch intent is what extensions
 * restart the app with; nothing else is installed.
 */
public class PackageManager {
    public static final int PERMISSION_GRANTED = 0;
    public static final int PERMISSION_DENIED = -1;

    /** The activity a restart names: CloudStream's, which the engine's context is. */
    private static final String LAUNCH_ACTIVITY = "com.lagradost.cloudstream3.MainActivity";

    public static class NameNotFoundException extends Exception {
        public NameNotFoundException() {}

        public NameNotFoundException(String name) {
            super(name);
        }
    }

    private static boolean isOwn(String packageName) {
        return StubEnv.packageName().equals(packageName);
    }

    public Intent getLaunchIntentForPackage(String packageName) {
        if (!isOwn(packageName)) return null;
        Intent intent = new Intent(Intent.ACTION_MAIN);
        intent.addCategory(Intent.CATEGORY_LAUNCHER);
        intent.setClassName(packageName, LAUNCH_ACTIVITY);
        intent.setPackage(packageName);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        return intent;
    }

    public PackageInfo getPackageInfo(String packageName, int flags) throws NameNotFoundException {
        if (!isOwn(packageName)) throw new NameNotFoundException(packageName);
        PackageInfo info = new PackageInfo();
        info.packageName = packageName;
        info.versionName = "1.0";
        info.versionCode = 1;
        info.applicationInfo = getApplicationInfo(packageName, flags);
        return info;
    }

    public ApplicationInfo getApplicationInfo(String packageName, int flags) throws NameNotFoundException {
        if (!isOwn(packageName)) throw new NameNotFoundException(packageName);
        ApplicationInfo info = new ApplicationInfo();
        info.packageName = packageName;
        info.dataDir = StubEnv.root().getAbsolutePath();
        return info;
    }

    public CharSequence getApplicationLabel(ApplicationInfo info) { return info.loadLabel(this); }
    public List<PackageInfo> getInstalledPackages(int flags) { return new ArrayList<>(); }
    public boolean hasSystemFeature(String featureName) { return false; }
    public int checkPermission(String permName, String packageName) { return PERMISSION_GRANTED; }
}
