package dev.akash.cs3engine.stubs;

import java.io.File;

/** Where the JVM stand-ins keep their state. The engine sets {@code cs3.dataDir} at start-up. */
public final class StubEnv {
    private StubEnv() {}

    public static File root() {
        String dir = System.getProperty("cs3.dataDir");
        File root = dir != null ? new File(dir) : new File(System.getProperty("java.io.tmpdir"), "cs3-engine");
        root.mkdirs();
        return root;
    }

    public static File dir(String name) {
        File dir = new File(root(), name);
        dir.mkdirs();
        return dir;
    }

    public static String packageName() {
        return System.getProperty("cs3.packageName", "dev.akash.cs3engine");
    }

    /** The app's name, as Android's manifest label gives it: extensions show it (FshareProvider). */
    public static String appLabel() {
        return System.getProperty("cs3.appLabel", "SkyStream");
    }

    /** The app's language (the engine's setLanguage sets it): extensions' resources and configuration follow it. */
    public static String language() {
        String language = System.getProperty("cs3.language");
        return language == null || language.isEmpty() ? "en" : language;
    }
}
