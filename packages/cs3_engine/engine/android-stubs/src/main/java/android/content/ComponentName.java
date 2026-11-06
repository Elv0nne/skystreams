package android.content;

import android.os.Parcelable;

/** An app component's package and class: what a restart's intent names. */
public final class ComponentName implements Parcelable, Cloneable, Comparable<ComponentName> {
    private final String packageName;
    private final String className;

    public ComponentName(String pkg, String cls) {
        if (pkg == null) throw new NullPointerException("package name is null");
        if (cls == null) throw new NullPointerException("class name is null");
        this.packageName = pkg;
        this.className = cls;
    }

    public ComponentName(Context pkg, String cls) {
        this(pkg.getPackageName(), cls);
    }

    public ComponentName(Context pkg, Class<?> cls) {
        this(pkg.getPackageName(), cls.getName());
    }

    public String getPackageName() { return packageName; }
    public String getClassName() { return className; }

    public String getShortClassName() {
        return className.startsWith(packageName + ".") ? className.substring(packageName.length()) : className;
    }

    public String flattenToString() { return packageName + "/" + className; }
    public String flattenToShortString() { return packageName + "/" + getShortClassName(); }

    public static ComponentName unflattenFromString(String str) {
        int slash = str.indexOf('/');
        if (slash < 0 || slash + 1 >= str.length()) return null;
        String pkg = str.substring(0, slash);
        String cls = str.substring(slash + 1);
        return new ComponentName(pkg, cls.startsWith(".") ? pkg + cls : cls);
    }

    @Override public ComponentName clone() { return new ComponentName(packageName, className); }
    @Override public int describeContents() { return 0; }

    @Override public int compareTo(ComponentName that) {
        int byPackage = packageName.compareTo(that.packageName);
        return byPackage != 0 ? byPackage : className.compareTo(that.className);
    }

    @Override public boolean equals(Object o) {
        return o instanceof ComponentName && packageName.equals(((ComponentName) o).packageName) && className.equals(((ComponentName) o).className);
    }

    @Override public int hashCode() { return packageName.hashCode() + className.hashCode(); }
    @Override public String toString() { return "ComponentInfo{" + packageName + "/" + className + "}"; }
}
