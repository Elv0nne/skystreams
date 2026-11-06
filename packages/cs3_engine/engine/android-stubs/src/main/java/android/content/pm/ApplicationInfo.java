package android.content.pm;

public class ApplicationInfo {
    public String packageName;
    public String name;
    public CharSequence nonLocalizedLabel;
    public String dataDir;
    public String sourceDir;
    public String nativeLibraryDir;
    public int flags;
    public int targetSdkVersion = 35;
    public int minSdkVersion = 21;

    /**
     * Its label, in Android's order: its own, its class name, its package, so never null (FshareProvider's load
     * reads it). The engine's context gives the app's name as its own (StubEnv.appLabel).
     */
    public CharSequence loadLabel(PackageManager pm) {
        if (nonLocalizedLabel != null) return nonLocalizedLabel;
        if (name != null) return name;
        return packageName;
    }
}
