package android.util;

import java.io.PrintWriter;
import java.io.StringWriter;

/** Writes to stderr; stdout is reserved for the engine protocol on desktop. */
public final class Log {
    public static final int VERBOSE = 2, DEBUG = 3, INFO = 4, WARN = 5, ERROR = 6, ASSERT = 7;
    private static final String[] NAMES = {"", "", "V", "D", "I", "W", "E", "A"};

    private Log() {}

    public static int println(int priority, String tag, String msg) {
        String line = NAMES[Math.max(0, Math.min(priority, 7))] + "/" + tag + ": " + msg;
        System.err.println(line);
        return line.length();
    }

    private static int println(int priority, String tag, String msg, Throwable tr) {
        return println(priority, tag, tr == null ? msg : msg + '\n' + getStackTraceString(tr));
    }

    public static int v(String tag, String msg) { return println(VERBOSE, tag, msg); }
    public static int v(String tag, String msg, Throwable tr) { return println(VERBOSE, tag, msg, tr); }
    public static int d(String tag, String msg) { return println(DEBUG, tag, msg); }
    public static int d(String tag, String msg, Throwable tr) { return println(DEBUG, tag, msg, tr); }
    public static int i(String tag, String msg) { return println(INFO, tag, msg); }
    public static int i(String tag, String msg, Throwable tr) { return println(INFO, tag, msg, tr); }
    public static int w(String tag, String msg) { return println(WARN, tag, msg); }
    public static int w(String tag, String msg, Throwable tr) { return println(WARN, tag, msg, tr); }
    public static int w(String tag, Throwable tr) { return println(WARN, tag, "", tr); }
    public static int e(String tag, String msg) { return println(ERROR, tag, msg); }
    public static int e(String tag, String msg, Throwable tr) { return println(ERROR, tag, msg, tr); }
    public static int wtf(String tag, String msg) { return println(ASSERT, tag, msg); }
    public static int wtf(String tag, String msg, Throwable tr) { return println(ASSERT, tag, msg, tr); }
    public static boolean isLoggable(String tag, int level) { return level >= INFO; }

    public static String getStackTraceString(Throwable tr) {
        if (tr == null) return "";
        StringWriter sw = new StringWriter();
        tr.printStackTrace(new PrintWriter(sw));
        return sw.toString();
    }
}
