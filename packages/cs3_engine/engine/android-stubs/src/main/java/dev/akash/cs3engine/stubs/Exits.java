package dev.akash.cs3engine.stubs;

/**
 * Where the DEX converter sends an extension's exits (the spec's "Exits are blocked twice"): System.exit,
 * Runtime.exit and halt, Process.killProcess, and Kotlin's exitProcess. On the JVM an exit would end the
 * engine, and on iOS the whole app; the platform stops the extension's code instead, and reloads it.
 */
public final class Exits {
    private Exits() {}

    public static void exit(int status) {
        Platform.host().exit(status);
        throw new IllegalStateException("the platform let exit(" + status + ") through");
    }

    /** Runtime.getRuntime().exit(status), its receiver passed along. */
    public static void exit(Runtime runtime, int status) {
        exit(status);
    }

    public static void halt(Runtime runtime, int status) {
        exit(status);
    }

    /** Process.killProcess: the extension's own process is the only one it could mean. */
    public static void killProcess(int pid) {
        exit(0);
    }

    /** kotlin.system.exitProcess, when an extension calls it rather than inlining it. */
    public static Void exitProcess(int status) {
        exit(status);
        return null;
    }
}
