package dev.akash.cs3engine.stubs;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * An extension's {@code resources.arsc}, read whole: every entry of its package, in every configuration it
 * has (the spec's "Resources"). {@link ResourceTable} picks the one a lookup gets. Reads what aapt2 writes:
 * UTF-8 and UTF-16 string pools (CESU-8 for characters past U+FFFF), plain, 16-bit and sparse entry
 * offsets, and compact entries.
 */
public final class Arsc {
    public static final int TYPE_NULL = 0x00;
    public static final int TYPE_REFERENCE = 0x01;
    public static final int TYPE_ATTRIBUTE = 0x02;
    public static final int TYPE_STRING = 0x03;
    public static final int TYPE_FLOAT = 0x04;
    public static final int TYPE_DIMENSION = 0x05;
    public static final int TYPE_FRACTION = 0x06;
    public static final int TYPE_INT_DEC = 0x10;
    public static final int TYPE_INT_HEX = 0x11;
    public static final int TYPE_INT_BOOLEAN = 0x12;
    public static final int TYPE_FIRST_COLOR_INT = 0x1c;
    public static final int TYPE_LAST_COLOR_INT = 0x1f;

    private static final int FLAG_SPARSE = 0x01;
    private static final int FLAG_OFFSET16 = 0x02;
    private static final int ENTRY_COMPLEX = 0x0001;
    private static final int ENTRY_COMPACT = 0x0008;
    private static final int[] NO_KEYS = new int[0];
    private static final Value[] NO_VALUES = new Value[0];

    /** A value as compiled: its type, its data, and its text when it's a string. */
    public static final class Value {
        public final int type;
        public final int data;
        public final String string;

        Value(int type, int data, String string) {
            this.type = type;
            this.data = data;
            this.string = string;
        }
    }

    /** A configuration's qualifiers, as far as a lookup cares. */
    public static final class Config {
        /** Its language ("hi"), or "" for none. */
        public final String language;
        /** Its region ("BR", or three digits), or "" for none. */
        public final String region;
        /** Its script ("Hant"), given or worked out by aapt2, or "" for none. */
        public final String script;
        /** 2 for night, 1 for not night, 0 for either. */
        public final int night;
        /** Its API level qualifier (aapt2 gives night v8), or 0. */
        public final int sdk;
        /** Whether it has any other qualifier (density, size, orientation, ...): not this device's. */
        public final boolean other;

        Config(String language, String region, String script, int night, int sdk, boolean other) {
            this.language = language;
            this.region = region;
            this.script = script;
            this.night = night;
            this.sdk = sdk;
            this.other = other;
        }
    }

    /** One resource in one configuration: a plain value, or a bag (an array, a style, plurals) of keyed values. */
    public static final class Entry {
        public final int id;
        public final String type;
        public final String name;
        public final Config config;
        /** The plain value; null for a bag. */
        public final Value value;
        /** A bag's keys (attribute ids, or array positions) and values; empty for a plain value. */
        public final int[] bagKeys;
        public final Value[] bagValues;

        Entry(int id, String type, String name, Config config, Value value, int[] bagKeys, Value[] bagValues) {
            this.id = id;
            this.type = type;
            this.name = name;
            this.config = config;
            this.value = value;
            this.bagKeys = bagKeys;
            this.bagValues = bagValues;
        }

        public boolean isBag() {
            return value == null;
        }
    }

    public final String packageName;
    public final int packageId;
    public final List<Entry> entries;

    private Arsc(String packageName, int packageId, List<Entry> entries) {
        this.packageName = packageName;
        this.packageId = packageId;
        this.entries = Collections.unmodifiableList(entries);
    }

    public static Arsc read(byte[] bytes) {
        ByteBuffer b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
        if (bytes.length < 12 || u16(b, 0) != 0x0002) throw new IllegalArgumentException("not a resources.arsc");
        String[] values = new String[0];
        List<Entry> entries = new ArrayList<>();
        String packageName = "";
        int packageId = 0x7f;
        boolean read = false;
        for (int pos = u16(b, 2); pos + 8 <= bytes.length; ) {
            int type = u16(b, pos);
            int size = b.getInt(pos + 4);
            if (size < 8 || pos + size > bytes.length) break;
            if (type == 0x0001) {
                values = strings(b, pos);
            } else if (type == 0x0200 && !read) {
                // An extension's table has one package: its own.
                read = true;
                packageId = b.getInt(pos + 8);
                packageName = utf16(b, pos + 12, 128);
                readPackage(b, pos, size, packageId, values, entries);
            }
            pos += size;
        }
        return new Arsc(packageName, packageId, entries);
    }

    private static void readPackage(ByteBuffer b, int start, int size, int packageId, String[] values, List<Entry> out) {
        String[] typeNames = strings(b, start + b.getInt(start + 268));
        String[] keys = strings(b, start + b.getInt(start + 276));
        for (int pos = start + u16(b, start + 2); pos + 8 <= start + size; ) {
            int chunk = b.getInt(pos + 4);
            if (chunk < 8) break;
            if (u16(b, pos) == 0x0201) readType(b, pos, packageId, typeNames, keys, values, out);
            pos += chunk;
        }
    }

    private static void readType(ByteBuffer b, int start, int packageId, String[] typeNames, String[] keys, String[] values, List<Entry> out) {
        int typeId = u8(b, start + 8);
        int flags = u8(b, start + 9);
        int count = b.getInt(start + 12);
        int entriesStart = b.getInt(start + 16);
        Config config = config(b, start + 20);
        String typeName = typeId >= 1 && typeId <= typeNames.length ? typeNames[typeId - 1] : "type" + typeId;
        int offsets = start + u16(b, start + 2);
        for (int i = 0; i < count; i++) {
            int index;
            int offset;
            if ((flags & FLAG_SPARSE) != 0) {
                index = u16(b, offsets + i * 4);
                offset = u16(b, offsets + i * 4 + 2) * 4;
            } else if ((flags & FLAG_OFFSET16) != 0) {
                index = i;
                int o = u16(b, offsets + i * 2);
                if (o == 0xffff) continue;
                offset = o * 4;
            } else {
                index = i;
                offset = b.getInt(offsets + i * 4);
                if (offset == -1) continue;
            }
            int e = start + entriesStart + offset;
            int id = (packageId << 24) | (typeId << 16) | index;
            int entryFlags = u16(b, e + 2);
            if ((entryFlags & ENTRY_COMPACT) != 0) {
                // The key's index sits where the size would, the value's type in the flags' high byte.
                out.add(new Entry(id, typeName, key(keys, u16(b, e)), config, value(entryFlags >>> 8, b.getInt(e + 4), values), NO_KEYS, NO_VALUES));
            } else if ((entryFlags & ENTRY_COMPLEX) != 0) {
                int entrySize = u16(b, e);
                int n = b.getInt(e + 12);
                int[] bagKeys = new int[n];
                Value[] bagValues = new Value[n];
                for (int j = 0; j < n; j++) {
                    int m = e + entrySize + j * 12;
                    bagKeys[j] = b.getInt(m);
                    bagValues[j] = value(u8(b, m + 7), b.getInt(m + 8), values);
                }
                out.add(new Entry(id, typeName, key(keys, b.getInt(e + 4)), config, null, bagKeys, bagValues));
            } else {
                int entrySize = u16(b, e);
                Value value = value(u8(b, e + entrySize + 3), b.getInt(e + entrySize + 4), values);
                out.add(new Entry(id, typeName, key(keys, b.getInt(e + 4)), config, value, NO_KEYS, NO_VALUES));
            }
        }
    }

    /** A ResTable_config's qualifiers; those past its size are zero, as Android reads an older table's. */
    private static Config config(ByteBuffer b, int at) {
        int size = Math.min(b.getInt(at), b.limit() - at);
        byte[] raw = new byte[64];
        for (int i = 0; i < Math.min(size, raw.length); i++) raw[i] = b.get(at + i);
        ByteBuffer c = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN);
        int uiMode = raw[29] & 0xff;
        int night = (uiMode & 0x30) == 0x20 ? 2 : (uiMode & 0x30) == 0x10 ? 1 : 0;
        boolean other = c.getShort(4) != 0 || c.getShort(6) != 0 // mcc, mnc
            || raw[12] != 0 || raw[13] != 0 || c.getShort(14) != 0 // orientation, touchscreen, density
            || raw[16] != 0 || raw[17] != 0 || raw[18] != 0 // keyboard, navigation, input flags
            || c.getInt(20) != 0 // screen size
            || raw[28] != 0 || (uiMode & 0x0f) != 0 || c.getShort(30) != 0 // screen layout, UI mode type, smallest width
            || c.getInt(32) != 0 // width and height in dp
            || c.getLong(40) != 0 // locale variant
            || raw[48] != 0 || raw[49] != 0; // screen layout 2, colour mode
        String script = raw[36] == 0 ? "" : new String(raw, 36, 4, java.nio.charset.StandardCharsets.US_ASCII);
        return new Config(packed(raw[8], raw[9], 'a'), packed(raw[10], raw[11], '0'), script, night, c.getShort(24) & 0xffff, other);
    }

    /** A config's language (base 'a') or region (base '0'): two characters, or three packed into two bytes. */
    private static String packed(byte first, byte second, char base) {
        if (first == 0) return "";
        if ((first & 0x80) != 0) {
            int a = second & 0x1f;
            int b = ((second & 0xe0) >> 5) | ((first & 0x03) << 3);
            int c = (first & 0x7c) >> 2;
            return new String(new char[] {(char) (base + a), (char) (base + b), (char) (base + c)});
        }
        return new String(new char[] {(char) first, (char) second});
    }

    /** A dimension's or fraction's number, from its compiled (complex) form. */
    public static float complexToFloat(int complex) {
        float[] radix = {1f, 1f / (1 << 7), 1f / (1 << 15), 1f / (1 << 23)};
        return (complex >> 8) * radix[(complex >> 4) & 3];
    }

    /** A string pool at [start]: UTF-8 (written as CESU-8) or UTF-16. */
    public static String[] strings(ByteBuffer b, int start) {
        int headerSize = u16(b, start + 2);
        int count = b.getInt(start + 8);
        int flags = b.getInt(start + 16);
        int stringsStart = b.getInt(start + 20);
        boolean utf8 = (flags & 0x100) != 0;
        String[] out = new String[count];
        for (int i = 0; i < count; i++) {
            int p = start + stringsStart + b.getInt(start + headerSize + i * 4);
            if (utf8) {
                p += (u8(b, p) & 0x80) != 0 ? 2 : 1; // its length in UTF-16 units
                int length = u8(b, p);
                if ((length & 0x80) != 0) {
                    length = ((length & 0x7f) << 8) | u8(b, p + 1);
                    p += 2;
                } else {
                    p += 1;
                }
                byte[] text = new byte[length];
                for (int j = 0; j < length; j++) text[j] = b.get(p + j);
                out[i] = cesu8(text);
            } else {
                int length = u16(b, p);
                if ((length & 0x8000) != 0) {
                    length = ((length & 0x7fff) << 16) | u16(b, p + 2);
                    p += 4;
                } else {
                    p += 2;
                }
                char[] text = new char[length];
                for (int j = 0; j < length; j++) text[j] = b.getChar(p + j * 2);
                out[i] = new String(text);
            }
        }
        return out;
    }

    /** aapt2 writes characters past U+FFFF as two three-byte surrogates (CESU-8), which a UTF-8 decoder rejects. */
    static String cesu8(byte[] bytes) {
        StringBuilder out = new StringBuilder(bytes.length);
        for (int i = 0; i < bytes.length; ) {
            int b0 = bytes[i] & 0xff;
            if (b0 < 0x80) {
                out.append((char) b0);
                i += 1;
            } else if ((b0 & 0xe0) == 0xc0 && i + 1 < bytes.length) {
                out.append((char) (((b0 & 0x1f) << 6) | (bytes[i + 1] & 0x3f)));
                i += 2;
            } else if ((b0 & 0xf0) == 0xe0 && i + 2 < bytes.length) {
                out.append((char) (((b0 & 0x0f) << 12) | ((bytes[i + 1] & 0x3f) << 6) | (bytes[i + 2] & 0x3f)));
                i += 3;
            } else if ((b0 & 0xf8) == 0xf0 && i + 3 < bytes.length) {
                out.appendCodePoint(((b0 & 0x07) << 18) | ((bytes[i + 1] & 0x3f) << 12) | ((bytes[i + 2] & 0x3f) << 6) | (bytes[i + 3] & 0x3f));
                i += 4;
            } else {
                out.append('�');
                i += 1;
            }
        }
        return out.toString();
    }

    private static Value value(int type, int data, String[] values) {
        return new Value(type, data, type == TYPE_STRING && data >= 0 && data < values.length ? values[data] : null);
    }

    private static String key(String[] keys, int index) {
        return index >= 0 && index < keys.length ? keys[index] : "#" + index;
    }

    private static String utf16(ByteBuffer b, int at, int max) {
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < max; i++) {
            char c = b.getChar(at + i * 2);
            if (c == 0) break;
            out.append(c);
        }
        return out.toString();
    }

    static int u8(ByteBuffer b, int at) {
        return b.get(at) & 0xff;
    }

    static int u16(ByteBuffer b, int at) {
        return b.getShort(at) & 0xffff;
    }
}
