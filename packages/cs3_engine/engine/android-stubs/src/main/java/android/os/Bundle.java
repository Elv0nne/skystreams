package android.os;

import java.io.Serializable;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/** Keyed values, kept as they are. A typed getter gives its default for a missing key or another type, as Android's. */
public final class Bundle implements Cloneable, Parcelable {
    public static final Bundle EMPTY = new Bundle();

    private final Map<String, Object> values = new LinkedHashMap<>();

    public Bundle() {}

    public Bundle(int capacity) {}

    public Bundle(ClassLoader loader) {}

    public Bundle(Bundle b) {
        if (b != null) values.putAll(b.values);
    }

    @SuppressWarnings("unchecked")
    private <T> T typed(String key, T defaultValue, Class<?> type) {
        Object value = values.get(key);
        return type.isInstance(value) ? (T) value : defaultValue;
    }

    public int size() { return values.size(); }
    public boolean isEmpty() { return values.isEmpty(); }
    public void clear() { values.clear(); }
    public boolean containsKey(String key) { return values.containsKey(key); }
    public Object get(String key) { return values.get(key); }
    public void remove(String key) { values.remove(key); }
    public Set<String> keySet() { return values.keySet(); }
    public void putAll(Bundle bundle) { if (bundle != null) values.putAll(bundle.values); }

    public void putBoolean(String key, boolean value) { values.put(key, value); }
    public void putByte(String key, byte value) { values.put(key, value); }
    public void putChar(String key, char value) { values.put(key, value); }
    public void putShort(String key, short value) { values.put(key, value); }
    public void putInt(String key, int value) { values.put(key, value); }
    public void putLong(String key, long value) { values.put(key, value); }
    public void putFloat(String key, float value) { values.put(key, value); }
    public void putDouble(String key, double value) { values.put(key, value); }
    public void putString(String key, String value) { values.put(key, value); }
    public void putCharSequence(String key, CharSequence value) { values.put(key, value); }
    public void putParcelable(String key, Parcelable value) { values.put(key, value); }
    public void putParcelableArrayList(String key, ArrayList<? extends Parcelable> value) { values.put(key, value); }
    public void putSerializable(String key, Serializable value) { values.put(key, value); }
    public void putIntegerArrayList(String key, ArrayList<Integer> value) { values.put(key, value); }
    public void putStringArrayList(String key, ArrayList<String> value) { values.put(key, value); }
    public void putBooleanArray(String key, boolean[] value) { values.put(key, value); }
    public void putByteArray(String key, byte[] value) { values.put(key, value); }
    public void putIntArray(String key, int[] value) { values.put(key, value); }
    public void putLongArray(String key, long[] value) { values.put(key, value); }
    public void putFloatArray(String key, float[] value) { values.put(key, value); }
    public void putStringArray(String key, String[] value) { values.put(key, value); }
    public void putBundle(String key, Bundle value) { values.put(key, value); }

    public boolean getBoolean(String key) { return getBoolean(key, false); }
    public boolean getBoolean(String key, boolean defaultValue) { return typed(key, defaultValue, Boolean.class); }
    public byte getByte(String key) { return getByte(key, (byte) 0); }
    public Byte getByte(String key, byte defaultValue) { return typed(key, defaultValue, Byte.class); }
    public char getChar(String key) { return getChar(key, (char) 0); }
    public char getChar(String key, char defaultValue) { return typed(key, defaultValue, Character.class); }
    public short getShort(String key) { return getShort(key, (short) 0); }
    public short getShort(String key, short defaultValue) { return typed(key, defaultValue, Short.class); }
    public int getInt(String key) { return getInt(key, 0); }
    public int getInt(String key, int defaultValue) { return typed(key, defaultValue, Integer.class); }
    public long getLong(String key) { return getLong(key, 0L); }
    public long getLong(String key, long defaultValue) { return typed(key, defaultValue, Long.class); }
    public float getFloat(String key) { return getFloat(key, 0f); }
    public float getFloat(String key, float defaultValue) { return typed(key, defaultValue, Float.class); }
    public double getDouble(String key) { return getDouble(key, 0.0); }
    public double getDouble(String key, double defaultValue) { return typed(key, defaultValue, Double.class); }
    public String getString(String key) { return typed(key, null, String.class); }
    public String getString(String key, String defaultValue) { String value = getString(key); return value == null ? defaultValue : value; }
    public CharSequence getCharSequence(String key) { return typed(key, null, CharSequence.class); }
    public CharSequence getCharSequence(String key, CharSequence defaultValue) { CharSequence value = getCharSequence(key); return value == null ? defaultValue : value; }
    public <T extends Parcelable> T getParcelable(String key) { return typed(key, null, Parcelable.class); }
    public <T> T getParcelable(String key, Class<T> clazz) { return typed(key, null, clazz); }
    public <T extends Parcelable> ArrayList<T> getParcelableArrayList(String key) { return typed(key, null, ArrayList.class); }
    public Serializable getSerializable(String key) { return typed(key, null, Serializable.class); }
    public <T extends Serializable> T getSerializable(String key, Class<T> clazz) { return typed(key, null, clazz); }
    public ArrayList<Integer> getIntegerArrayList(String key) { return typed(key, null, ArrayList.class); }
    public ArrayList<String> getStringArrayList(String key) { return typed(key, null, ArrayList.class); }
    public boolean[] getBooleanArray(String key) { return typed(key, null, boolean[].class); }
    public byte[] getByteArray(String key) { return typed(key, null, byte[].class); }
    public int[] getIntArray(String key) { return typed(key, null, int[].class); }
    public long[] getLongArray(String key) { return typed(key, null, long[].class); }
    public float[] getFloatArray(String key) { return typed(key, null, float[].class); }
    public String[] getStringArray(String key) { return typed(key, null, String[].class); }
    public Bundle getBundle(String key) { return typed(key, null, Bundle.class); }

    @Override public int describeContents() { return 0; }
    @Override public Object clone() { return new Bundle(this); }
    @Override public String toString() { return "Bundle[" + values + "]"; }
}
