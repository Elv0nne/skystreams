package dev.akash.cs3engine.stubs;

import android.content.SharedPreferences;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.util.Arrays;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * {@link SharedPreferences} backed by a properties file per name, so plugin settings and
 * tokens survive restarts. Values carry a one-letter type prefix: s, i, l, f, b, or S for
 * a string set (entries joined with U+0000).
 */
public final class FilePreferences implements SharedPreferences {
    private static final Map<String, FilePreferences> INSTANCES = new ConcurrentHashMap<>();
    private static final String SET_SEPARATOR = "\u0000";

    private final File file;
    private final Map<String, Object> values = new ConcurrentHashMap<>();
    private final List<OnSharedPreferenceChangeListener> listeners = new CopyOnWriteArrayList<>();

    public static SharedPreferences get(String name) {
        return INSTANCES.computeIfAbsent(name, n -> new FilePreferences(new File(StubEnv.dir("shared_prefs"), n + ".properties")));
    }

    private FilePreferences(File file) {
        this.file = file;
        if (!file.exists()) return;
        Properties props = new Properties();
        try (InputStream in = new FileInputStream(file)) {
            props.load(in);
        } catch (IOException e) {
            System.err.println("[cs3] could not read " + file + ": " + e);
        }
        for (String key : props.stringPropertyNames()) {
            Object value = decode(props.getProperty(key));
            if (value != null) values.put(key, value);
        }
    }

    private static Object decode(String raw) {
        if (raw.length() < 2 || raw.charAt(1) != ':') return raw;
        String v = raw.substring(2);
        switch (raw.charAt(0)) {
            case 's': return v;
            case 'i': return Integer.valueOf(v);
            case 'l': return Long.valueOf(v);
            case 'f': return Float.valueOf(v);
            case 'b': return Boolean.valueOf(v);
            case 'S': return v.isEmpty() ? new LinkedHashSet<String>() : new LinkedHashSet<>(Arrays.asList(v.split(SET_SEPARATOR, -1)));
            default: return raw;
        }
    }

    private static String encode(Object value) {
        if (value instanceof Integer) return "i:" + value;
        if (value instanceof Long) return "l:" + value;
        if (value instanceof Float) return "f:" + value;
        if (value instanceof Boolean) return "b:" + value;
        if (value instanceof Set) return "S:" + String.join(SET_SEPARATOR, (Set<String>) value);
        return "s:" + value;
    }

    private synchronized void persist() {
        Properties props = new Properties();
        values.forEach((k, v) -> props.setProperty(k, encode(v)));
        File tmp = new File(file.getPath() + ".tmp");
        try (OutputStream out = new FileOutputStream(tmp)) {
            props.store(out, null);
        } catch (IOException e) {
            System.err.println("[cs3] could not write " + file + ": " + e);
            return;
        }
        // File.renameTo cannot replace an existing file on Windows.
        try {
            try {
                Files.move(tmp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
            } catch (AtomicMoveNotSupportedException e) {
                Files.move(tmp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING);
            }
        } catch (IOException e) {
            System.err.println("[cs3] could not replace " + file + ": " + e);
        }
    }

    /** Drops listeners whose code {@code classLoader} loaded: a plugin being unloaded. */
    public static void removeListenersFrom(ClassLoader classLoader) {
        for (FilePreferences prefs : INSTANCES.values()) {
            prefs.listeners.removeIf(l -> l.getClass().getClassLoader() == classLoader);
        }
    }

    @SuppressWarnings("unchecked")
    private <T> T typed(String key, T defValue, Class<T> type) {
        Object value = values.get(key);
        return type.isInstance(value) ? (T) value : defValue;
    }

    @Override public Map<String, ?> getAll() { return new HashMap<>(values); }
    @Override public String getString(String key, String defValue) { return typed(key, defValue, String.class); }
    @SuppressWarnings("unchecked")
    @Override public Set<String> getStringSet(String key, Set<String> defValues) { return typed(key, defValues, Set.class); }
    @Override public int getInt(String key, int defValue) { return typed(key, defValue, Integer.class); }
    @Override public long getLong(String key, long defValue) { return typed(key, defValue, Long.class); }
    @Override public float getFloat(String key, float defValue) { return typed(key, defValue, Float.class); }
    @Override public boolean getBoolean(String key, boolean defValue) { return typed(key, defValue, Boolean.class); }
    @Override public boolean contains(String key) { return values.containsKey(key); }
    @Override public Editor edit() { return new FileEditor(); }
    @Override public void registerOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener l) { listeners.add(l); }
    @Override public void unregisterOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener l) { listeners.remove(l); }

    private final class FileEditor implements Editor {
        private final Map<String, Object> pending = new HashMap<>();
        private final Set<String> removed = new LinkedHashSet<>();
        private boolean clear;

        private Editor put(String key, Object value) {
            if (value == null) return remove(key);
            pending.put(key, value);
            removed.remove(key);
            return this;
        }

        @Override public Editor putString(String key, String value) { return put(key, value); }
        @Override public Editor putStringSet(String key, Set<String> values) { return put(key, values == null ? null : new LinkedHashSet<>(values)); }
        @Override public Editor putInt(String key, int value) { return put(key, value); }
        @Override public Editor putLong(String key, long value) { return put(key, value); }
        @Override public Editor putFloat(String key, float value) { return put(key, value); }
        @Override public Editor putBoolean(String key, boolean value) { return put(key, value); }
        @Override public Editor remove(String key) { pending.remove(key); removed.add(key); return this; }
        @Override public Editor clear() { clear = true; return this; }

        @Override public boolean commit() {
            Set<String> changed = new LinkedHashSet<>(pending.keySet());
            changed.addAll(removed);
            if (clear) {
                changed.addAll(values.keySet());
                values.clear();
            }
            removed.forEach(values::remove);
            values.putAll(pending);
            persist();
            for (String key : changed) {
                for (OnSharedPreferenceChangeListener l : listeners) l.onSharedPreferenceChanged(FilePreferences.this, key);
            }
            return true;
        }

        @Override public void apply() { commit(); }
    }
}
