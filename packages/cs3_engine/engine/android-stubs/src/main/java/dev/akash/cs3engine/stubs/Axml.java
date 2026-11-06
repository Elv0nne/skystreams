package dev.akash.cs3engine.stubs;

import android.content.res.Resources;
import android.content.res.XmlResourceParser;
import android.util.AttributeSet;
import android.util.DisplayMetrics;
import android.util.TypedValue;
import java.io.InputStream;
import java.io.Reader;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.xmlpull.v1.XmlPullParserException;

/**
 * Android's compiled XML (a layout, a preference screen), read whole and served as a pull parser
 * (the spec's "Resources"). [resources] is where it came from: its references and the extension's classes.
 */
public final class Axml implements XmlResourceParser {
    public static final String ANDROID = "http://schemas.android.com/apk/res/android";
    private static final String[] DIMENSION_UNITS = {"px", "dip", "sp", "pt", "in", "mm"};

    /** An attribute as compiled: its namespace and name, the text it kept (strings), and its typed value. */
    public static final class Attribute {
        public final String namespace;
        public final String name;
        public final String raw;
        public final int type;
        public final int data;
        /** Its name's resource id (android:id is 0x010100d0), or 0. */
        public final int resourceId;

        Attribute(String namespace, String name, String raw, int type, int data, int resourceId) {
            this.namespace = namespace;
            this.name = name;
            this.raw = raw;
            this.type = type;
            this.data = data;
            this.resourceId = resourceId;
        }

        /** Its value as text: what it kept, else its typed value as Android writes one. */
        public String value() {
            return raw != null ? raw : coerce(type, data);
        }
    }

    private static final class Event {
        final int type;
        final String namespace;
        final String name;
        final String text;
        final List<Attribute> attributes;
        final int depth;
        final int line;

        Event(int type, String namespace, String name, String text, List<Attribute> attributes, int depth, int line) {
            this.type = type;
            this.namespace = namespace;
            this.name = name;
            this.text = text;
            this.attributes = attributes;
            this.depth = depth;
            this.line = line;
        }
    }

    private final List<Event> events = new ArrayList<>();
    private final Map<String, String> prefixes = new HashMap<>();
    private int index;

    /** The resources it came from; whoever opens it sets this. */
    public Resources resources;
    /** The extension's class loader, for the views it names; whoever opens it sets this. */
    public ClassLoader classLoader;
    /** Views View's constructor was given the current element for (LayoutAttributes); the inflater clears it per element. */
    public final List<Object> made = new ArrayList<>();

    public Axml(byte[] bytes) {
        ByteBuffer b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
        if (bytes.length < 8 || Arsc.u16(b, 0) != 0x0003) throw new IllegalArgumentException("not compiled XML");
        String[] strings = new String[0];
        int[] resourceIds = new int[0];
        int depth = 0;
        events.add(new Event(START_DOCUMENT, null, null, null, Collections.emptyList(), 0, 0));
        for (int pos = Arsc.u16(b, 2); pos + 8 <= bytes.length; ) {
            int type = Arsc.u16(b, pos);
            int headerSize = Arsc.u16(b, pos + 2);
            int size = b.getInt(pos + 4);
            if (size < 8 || pos + size > bytes.length) break;
            int ext = pos + headerSize;
            int line = type >= 0x0100 && type <= 0x017f ? b.getInt(pos + 8) : 0;
            if (type == 0x0001) {
                strings = Arsc.strings(b, pos);
            } else if (type == 0x0180) {
                resourceIds = new int[(size - headerSize) / 4];
                for (int i = 0; i < resourceIds.length; i++) resourceIds[i] = b.getInt(ext + i * 4);
            } else if (type == 0x0100) {
                String prefix = string(strings, b.getInt(ext));
                String uri = string(strings, b.getInt(ext + 4));
                if (uri != null) prefixes.put(uri, prefix);
            } else if (type == 0x0102) {
                int attributeStart = Arsc.u16(b, ext + 8);
                int attributeSize = Arsc.u16(b, ext + 10);
                int count = Arsc.u16(b, ext + 12);
                List<Attribute> attributes = new ArrayList<>(count);
                for (int i = 0; i < count; i++) {
                    int a = ext + attributeStart + i * attributeSize;
                    int nameIndex = b.getInt(a + 4);
                    attributes.add(new Attribute(
                        string(strings, b.getInt(a)),
                        string(strings, nameIndex),
                        string(strings, b.getInt(a + 8)),
                        Arsc.u8(b, a + 15),
                        b.getInt(a + 16),
                        nameIndex >= 0 && nameIndex < resourceIds.length ? resourceIds[nameIndex] : 0));
                }
                String namespace = string(strings, b.getInt(ext));
                events.add(new Event(START_TAG, namespace, string(strings, b.getInt(ext + 4)), null, attributes, ++depth, line));
            } else if (type == 0x0103) {
                events.add(new Event(END_TAG, string(strings, b.getInt(ext)), string(strings, b.getInt(ext + 4)), null, Collections.emptyList(), depth--, line));
            } else if (type == 0x0104) {
                events.add(new Event(TEXT, null, null, string(strings, b.getInt(ext)), Collections.emptyList(), depth, line));
            }
            pos += size;
        }
        events.add(new Event(END_DOCUMENT, null, null, null, Collections.emptyList(), 0, 0));
    }

    private static String string(String[] strings, int index) {
        return index >= 0 && index < strings.length ? strings[index] : null;
    }

    private Event current() {
        return events.get(index);
    }

    /** The current start tag's attributes, typed. */
    public List<Attribute> attributes() {
        return current().attributes;
    }

    /**
     * The current tag's attribute [name] in [namespace], or null. A null namespace matches any; "" matches
     * none, as the XML `id`, `class` and `style` attributes have.
     */
    public Attribute attribute(String namespace, String name) {
        for (Attribute a : current().attributes) {
            if (name.equals(a.name) && (namespace == null || namespace.equals(a.namespace == null ? "" : a.namespace))) return a;
        }
        return null;
    }

    /** Whether the current start tag has elements inside it, before its end tag. */
    public boolean hasChildElements() {
        Event start = current();
        if (start.type != START_TAG) return false;
        for (int i = index + 1; i < events.size(); i++) {
            Event event = events.get(i);
            if (event.type == START_TAG) return true;
            if (event.type == END_TAG && event.depth == start.depth) return false;
        }
        return false;
    }

    /** A typed value as text, the way Android's TypedValue.coerceToString writes it. */
    public static String coerce(int type, int data) {
        switch (type) {
            case Arsc.TYPE_NULL: return null;
            case Arsc.TYPE_REFERENCE: return "@" + data;
            case Arsc.TYPE_ATTRIBUTE: return "?" + data;
            case Arsc.TYPE_FLOAT: return Float.toString(Float.intBitsToFloat(data));
            case Arsc.TYPE_DIMENSION: return Arsc.complexToFloat(data) + DIMENSION_UNITS[Math.min(data & 0xf, 5)];
            case Arsc.TYPE_FRACTION: return Arsc.complexToFloat(data) * 100 + ((data & 0xf) == 1 ? "%p" : "%");
            case Arsc.TYPE_INT_HEX: return "0x" + Integer.toHexString(data);
            case Arsc.TYPE_INT_BOOLEAN: return data != 0 ? "true" : "false";
            default:
                if (type >= Arsc.TYPE_FIRST_COLOR_INT && type <= Arsc.TYPE_LAST_COLOR_INT) return String.format("#%08x", data);
                return Integer.toString(data);
        }
    }

    /**
     * A layout_width or layout_height in [attrs]: match_parent (-1), wrap_content (-2), or pixels at the
     * stand-ins' density; wrap_content when it isn't there.
     */
    public static int layoutSize(AttributeSet attrs, String name) {
        if (attrs instanceof Axml) {
            Attribute a = ((Axml) attrs).attribute(ANDROID, name);
            if (a == null) return -2;
            if (a.type == Arsc.TYPE_DIMENSION) return TypedValue.complexToDimensionPixelSize(a.data, new DisplayMetrics());
            if (a.type == Arsc.TYPE_INT_DEC || a.type == Arsc.TYPE_INT_HEX) return a.data;
            return -2;
        }
        return attrs == null ? -2 : attrs.getAttributeIntValue(ANDROID, name, -2);
    }

    // XmlPullParser

    @Override public int getEventType() { return current().type; }

    @Override public int next() {
        if (index < events.size() - 1) index++;
        return current().type;
    }

    @Override public int nextToken() { return next(); }

    @Override public int nextTag() throws XmlPullParserException {
        int type = next();
        while (type == TEXT && isWhitespace()) type = next();
        if (type != START_TAG && type != END_TAG) throw new XmlPullParserException("expected a start or end tag", this, null);
        return type;
    }

    @Override public String nextText() throws XmlPullParserException {
        if (getEventType() != START_TAG) throw new XmlPullParserException("nextText() needs a start tag", this, null);
        int type = next();
        if (type == END_TAG) return "";
        if (type != TEXT) throw new XmlPullParserException("expected text", this, null);
        String text = getText();
        if (next() != END_TAG) throw new XmlPullParserException("expected an end tag after text", this, null);
        return text;
    }

    @Override public void require(int type, String namespace, String name) throws XmlPullParserException {
        if (type != getEventType()
            || (namespace != null && !namespace.equals(getNamespace()))
            || (name != null && !name.equals(getName()))) {
            throw new XmlPullParserException("expected " + TYPES[type] + (name == null ? "" : " " + name), this, null);
        }
    }

    @Override public String getName() { return current().name; }
    @Override public String getNamespace() { return current().namespace == null ? (current().name == null ? null : "") : current().namespace; }
    @Override public String getPrefix() { return current().namespace == null ? null : prefixes.get(current().namespace); }
    @Override public int getDepth() { return current().depth; }
    @Override public String getText() { return current().text; }

    @Override public char[] getTextCharacters(int[] holderForStartAndLength) {
        String text = getText();
        if (text == null) {
            holderForStartAndLength[0] = -1;
            holderForStartAndLength[1] = -1;
            return null;
        }
        holderForStartAndLength[0] = 0;
        holderForStartAndLength[1] = text.length();
        return text.toCharArray();
    }

    @Override public boolean isWhitespace() { return getText() == null || getText().trim().isEmpty(); }
    @Override public boolean isEmptyElementTag() { return false; }
    @Override public int getAttributeCount() { return getEventType() == START_TAG ? current().attributes.size() : -1; }
    @Override public String getAttributeNamespace(int index) { String ns = current().attributes.get(index).namespace; return ns == null ? "" : ns; }
    @Override public String getAttributeName(int index) { return current().attributes.get(index).name; }
    @Override public String getAttributePrefix(int index) { return prefixes.get(current().attributes.get(index).namespace); }
    @Override public String getAttributeType(int index) { return "CDATA"; }
    @Override public boolean isAttributeDefault(int index) { return false; }
    @Override public String getAttributeValue(int index) { return current().attributes.get(index).value(); }

    @Override public String getAttributeValue(String namespace, String name) {
        Attribute a = attribute(namespace, name);
        return a == null ? null : a.value();
    }

    @Override public int getLineNumber() { return current().line; }
    @Override public int getColumnNumber() { return -1; }
    @Override public String getPositionDescription() { return "Binary XML file line #" + getLineNumber(); }
    @Override public void setFeature(String name, boolean state) {}
    @Override public boolean getFeature(String name) { return FEATURE_PROCESS_NAMESPACES.equals(name); }
    @Override public void setProperty(String name, Object value) {}
    @Override public Object getProperty(String name) { return null; }

    @Override public void setInput(Reader in) throws XmlPullParserException {
        throw new XmlPullParserException("compiled XML is read from its bytes");
    }

    @Override public void setInput(InputStream inputStream, String inputEncoding) throws XmlPullParserException {
        throw new XmlPullParserException("compiled XML is read from its bytes");
    }

    @Override public String getInputEncoding() { return "UTF-8"; }
    @Override public void defineEntityReplacementText(String entityName, String replacementText) {}
    @Override public int getNamespaceCount(int depth) { return depth > 0 ? prefixes.size() : 0; }
    @Override public String getNamespacePrefix(int pos) { return new ArrayList<>(prefixes.values()).get(pos); }
    @Override public String getNamespaceUri(int pos) { return new ArrayList<>(prefixes.keySet()).get(pos); }

    @Override public String getNamespace(String prefix) {
        for (Map.Entry<String, String> e : prefixes.entrySet()) if (e.getValue().equals(prefix)) return e.getKey();
        return null;
    }

    // AttributeSet

    @Override public int getAttributeNameResource(int index) { return current().attributes.get(index).resourceId; }

    @Override public int getAttributeListValue(String namespace, String attribute, String[] options, int defaultValue) {
        return listValue(attribute(namespace, attribute), options, defaultValue);
    }

    @Override public boolean getAttributeBooleanValue(String namespace, String attribute, boolean defaultValue) {
        return booleanValue(attribute(namespace, attribute), defaultValue);
    }

    @Override public int getAttributeResourceValue(String namespace, String attribute, int defaultValue) {
        return resourceValue(attribute(namespace, attribute), defaultValue);
    }

    @Override public int getAttributeIntValue(String namespace, String attribute, int defaultValue) {
        return intValue(attribute(namespace, attribute), defaultValue);
    }

    @Override public int getAttributeUnsignedIntValue(String namespace, String attribute, int defaultValue) {
        return intValue(attribute(namespace, attribute), defaultValue);
    }

    @Override public float getAttributeFloatValue(String namespace, String attribute, float defaultValue) {
        return floatValue(attribute(namespace, attribute), defaultValue);
    }

    @Override public int getAttributeListValue(int index, String[] options, int defaultValue) {
        return listValue(current().attributes.get(index), options, defaultValue);
    }

    @Override public boolean getAttributeBooleanValue(int index, boolean defaultValue) {
        return booleanValue(current().attributes.get(index), defaultValue);
    }

    @Override public int getAttributeResourceValue(int index, int defaultValue) {
        return resourceValue(current().attributes.get(index), defaultValue);
    }

    @Override public int getAttributeIntValue(int index, int defaultValue) {
        return intValue(current().attributes.get(index), defaultValue);
    }

    @Override public int getAttributeUnsignedIntValue(int index, int defaultValue) {
        return intValue(current().attributes.get(index), defaultValue);
    }

    @Override public float getAttributeFloatValue(int index, float defaultValue) {
        return floatValue(current().attributes.get(index), defaultValue);
    }

    @Override public String getIdAttribute() { return getAttributeValue("", "id"); }
    @Override public String getClassAttribute() { return getAttributeValue("", "class"); }
    @Override public int getIdAttributeResourceValue(int defaultValue) { return resourceValue(attribute("", "id"), defaultValue); }
    @Override public int getStyleAttribute() { return resourceValue(attribute("", "style"), 0); }
    @Override public void close() {}

    private static int listValue(Attribute a, String[] options, int defaultValue) {
        if (a == null) return defaultValue;
        String value = a.value();
        for (int i = 0; i < options.length; i++) if (options[i].equals(value)) return i;
        return defaultValue;
    }

    private static boolean booleanValue(Attribute a, boolean defaultValue) {
        if (a == null) return defaultValue;
        if (a.type == Arsc.TYPE_INT_BOOLEAN) return a.data != 0;
        return a.raw != null ? Boolean.parseBoolean(a.raw.trim()) : defaultValue;
    }

    private static int resourceValue(Attribute a, int defaultValue) {
        return a != null && a.type == Arsc.TYPE_REFERENCE ? a.data : defaultValue;
    }

    private static int intValue(Attribute a, int defaultValue) {
        if (a == null) return defaultValue;
        if (a.type >= Arsc.TYPE_INT_DEC && a.type <= Arsc.TYPE_LAST_COLOR_INT) return a.data;
        try {
            return a.raw != null ? Integer.decode(a.raw.trim()) : defaultValue;
        } catch (NumberFormatException e) {
            return defaultValue;
        }
    }

    private static float floatValue(Attribute a, float defaultValue) {
        if (a == null) return defaultValue;
        if (a.type == Arsc.TYPE_FLOAT) return Float.intBitsToFloat(a.data);
        try {
            return a.raw != null ? Float.parseFloat(a.raw.trim()) : defaultValue;
        } catch (NumberFormatException e) {
            return defaultValue;
        }
    }
}
