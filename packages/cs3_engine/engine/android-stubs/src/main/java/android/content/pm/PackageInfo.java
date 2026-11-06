package android.content.pm;

/** A package's details: only the engine's own package is installed. */
public class PackageInfo {
    public String packageName;
    public String versionName;
    @Deprecated
    public int versionCode;
    public ApplicationInfo applicationInfo;
    public long firstInstallTime;
    public long lastUpdateTime;
    public String[] requestedPermissions;

    public long getLongVersionCode() { return versionCode; }
    public void setLongVersionCode(long longVersionCode) { versionCode = (int) longVersionCode; }
}
