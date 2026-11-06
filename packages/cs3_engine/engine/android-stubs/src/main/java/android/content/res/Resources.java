package android.content.res;

import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.Drawable;
import android.util.AttributeSet;
import android.util.DisplayMetrics;
import android.util.TypedValue;
import dev.akash.cs3engine.stubs.Arsc;
import dev.akash.cs3engine.stubs.Axml;
import dev.akash.cs3engine.stubs.ResourceTable;
import dev.akash.cs3engine.stubs.StubEnv;
import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.util.HashMap;
import java.util.Map;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * An extension's resources, read from its .cs3 (the spec's "Resources"): resources.arsc as the stand-ins'
 * device sees it (night, the app's language), and compiled XML for layouts. The app's own
 * ({@link #getSystem()}) holds Android's common strings only. A missing id throws, as on Android.
 */
public class Resources {
    public static class NotFoundException extends RuntimeException {
        public NotFoundException() {}

        public NotFoundException(String name) {
            super(name);
        }

        public NotFoundException(String name, Exception cause) {
            super(name, cause);
        }
    }

    /** A theme: attributes aren't read off the JVM, so it answers as for unset ones. */
    public final class Theme {
        public void applyStyle(int resId, boolean force) {}
        public void setTo(Theme other) {}
        public TypedArray obtainStyledAttributes(int[] attrs) { return new TypedArray(attrs.length); }
        public TypedArray obtainStyledAttributes(int resId, int[] attrs) { return new TypedArray(attrs.length); }

        public TypedArray obtainStyledAttributes(AttributeSet set, int[] attrs, int defStyleAttr, int defStyleRes) {
            return new TypedArray(attrs.length);
        }

        public boolean resolveAttribute(int resid, TypedValue outValue, boolean resolveRefs) { return false; }
        public Resources getResources() { return Resources.this; }
    }

    /** Android's common strings, which every app and extension can use (android.R.string). */
    private static final Map<Integer, String> FRAMEWORK = new HashMap<>();

    static {
        FRAMEWORK.put(android.R.string.cancel, "Cancel");
        FRAMEWORK.put(android.R.string.copy, "Copy");
        FRAMEWORK.put(android.R.string.cut, "Cut");
        FRAMEWORK.put(android.R.string.dialog_alert_title, "Attention");
        FRAMEWORK.put(android.R.string.no, "No");
        FRAMEWORK.put(android.R.string.ok, "OK");
        FRAMEWORK.put(android.R.string.paste, "Paste");
        FRAMEWORK.put(android.R.string.search_go, "Search");
        FRAMEWORK.put(android.R.string.selectAll, "Select all");
        FRAMEWORK.put(android.R.string.unknownName, "Unknown");
        FRAMEWORK.put(android.R.string.untitled, "<Untitled>");
        FRAMEWORK.put(android.R.string.yes, "Yes");
    }

    private static final Resources SYSTEM = new Resources();
    private static final int PLURAL_OTHER = 0x01000004;
    private static final int PLURAL_ONE = 0x01000006;

    private final ResourceTable table;
    private final File file;
    private final ClassLoader classLoader;
    private final DisplayMetrics metrics = new DisplayMetrics();
    private final Configuration configuration = new Configuration();
    private final AssetManager assets;

    /** The app's: Android's common strings only. */
    public Resources() {
        this(null, null, Resources.class.getClassLoader());
    }

    private Resources(ResourceTable table, File file, ClassLoader classLoader) {
        this.table = table;
        this.file = file;
        this.classLoader = classLoader;
        this.assets = new AssetManager(file);
    }

    /** [cs3]'s resources, in the app's language now; inert when it has no table, or one that can't be read. */
    public static Resources of(File cs3, ClassLoader classLoader) {
        try (ZipFile zip = new ZipFile(cs3)) {
            ZipEntry entry = zip.getEntry("resources.arsc");
            if (entry == null) return new Resources(null, cs3, classLoader);
            byte[] bytes;
            try (InputStream in = zip.getInputStream(entry)) {
                bytes = in.readAllBytes();
            }
            return new Resources(new ResourceTable(Arsc.read(bytes), StubEnv.language()), cs3, classLoader);
        } catch (IOException | RuntimeException e) {
            System.err.println("[cs3] " + cs3.getName() + "'s resources can't be read: " + e);
            return new Resources(null, cs3, classLoader);
        }
    }

    public static Resources getSystem() { return SYSTEM; }
    public DisplayMetrics getDisplayMetrics() { return metrics; }
    public Configuration getConfiguration() { return configuration; }
    public final Theme newTheme() { return new Theme(); }
    public final AssetManager getAssets() { return assets; }
    public void updateConfiguration(Configuration config, DisplayMetrics metrics) {}

    private static NotFoundException notFound(int id) {
        return new NotFoundException("Resource ID #0x" + Integer.toHexString(id));
    }

    private Arsc.Entry entry(int id) {
        Arsc.Entry entry = table == null ? null : table.entry(id);
        if (entry == null) throw notFound(id);
        return entry;
    }

    /** [id]'s plain value, references followed (an alias such as @string/other). */
    private Arsc.Value value(int id) {
        Arsc.Value value = entry(id).value;
        for (int hops = 0; value != null && value.type == Arsc.TYPE_REFERENCE && hops < 8; hops++) {
            Arsc.Entry next = table.entry(value.data);
            if (next == null) break;
            value = next.value;
        }
        if (value == null) throw new NotFoundException("Resource ID #0x" + Integer.toHexString(id) + " isn't a plain value");
        return value;
    }

    public CharSequence getText(int id) {
        String framework = FRAMEWORK.get(id);
        if (framework != null) return framework;
        Arsc.Value value = value(id);
        if (value.string == null) throw new NotFoundException("String resource ID #0x" + Integer.toHexString(id));
        return value.string;
    }

    public CharSequence getText(int id, CharSequence def) {
        try {
            return getText(id);
        } catch (NotFoundException e) {
            return def;
        }
    }

    public String getString(int id) { return getText(id).toString(); }

    public String getString(int id, Object... formatArgs) {
        return String.format(configuration.getLocales().get(0), getString(id), formatArgs);
    }

    /** A plural's text: "one" for 1, else "other" (the languages the corpus ships need no more). */
    public CharSequence getQuantityText(int id, int quantity) {
        Arsc.Entry entry = entry(id);
        if (!entry.isBag()) return getText(id);
        int wanted = quantity == 1 ? PLURAL_ONE : PLURAL_OTHER;
        for (int i = 0; i < entry.bagKeys.length; i++) {
            if (entry.bagKeys[i] == wanted && entry.bagValues[i].string != null) return entry.bagValues[i].string;
        }
        for (int i = 0; i < entry.bagKeys.length; i++) {
            if (entry.bagKeys[i] == PLURAL_OTHER && entry.bagValues[i].string != null) return entry.bagValues[i].string;
        }
        throw new NotFoundException("Plural resource ID #0x" + Integer.toHexString(id));
    }

    public String getQuantityString(int id, int quantity) { return getQuantityText(id, quantity).toString(); }

    public String getQuantityString(int id, int quantity, Object... formatArgs) {
        return String.format(configuration.getLocales().get(0), getQuantityString(id, quantity), formatArgs);
    }

    public String[] getStringArray(int id) {
        Arsc.Entry entry = entry(id);
        if (!entry.isBag()) throw new NotFoundException("Array resource ID #0x" + Integer.toHexString(id));
        String[] out = new String[entry.bagValues.length];
        for (int i = 0; i < out.length; i++) {
            Arsc.Value item = entry.bagValues[i];
            out[i] = item.string != null ? item.string : item.type == Arsc.TYPE_REFERENCE ? getString(item.data) : Axml.coerce(item.type, item.data);
        }
        return out;
    }

    public CharSequence[] getTextArray(int id) { return getStringArray(id); }

    public int[] getIntArray(int id) {
        Arsc.Entry entry = entry(id);
        if (!entry.isBag()) throw new NotFoundException("Array resource ID #0x" + Integer.toHexString(id));
        int[] out = new int[entry.bagValues.length];
        for (int i = 0; i < out.length; i++) out[i] = entry.bagValues[i].data;
        return out;
    }

    public TypedArray obtainTypedArray(int id) { return new TypedArray(entry(id).bagValues.length); }

    public int getColor(int id) {
        Arsc.Value value = value(id);
        if (value.type < Arsc.TYPE_FIRST_COLOR_INT || value.type > Arsc.TYPE_LAST_COLOR_INT) {
            throw new NotFoundException("Resource ID #0x" + Integer.toHexString(id) + " isn't a colour");
        }
        return value.data;
    }

    public int getColor(int id, Theme theme) { return getColor(id); }

    /** A colour as a state list; a selector file (res/color) reads as black, its states unread. */
    public ColorStateList getColorStateList(int id) {
        Arsc.Value value = value(id);
        return ColorStateList.valueOf(value.string != null ? 0xFF000000 : getColor(id));
    }

    public ColorStateList getColorStateList(int id, Theme theme) { return getColorStateList(id); }

    public boolean getBoolean(int id) {
        Arsc.Value value = value(id);
        if (value.type != Arsc.TYPE_INT_BOOLEAN) throw new NotFoundException("Resource ID #0x" + Integer.toHexString(id) + " isn't a boolean");
        return value.data != 0;
    }

    public int getInteger(int id) {
        Arsc.Value value = value(id);
        if (value.type != Arsc.TYPE_INT_DEC && value.type != Arsc.TYPE_INT_HEX) {
            throw new NotFoundException("Resource ID #0x" + Integer.toHexString(id) + " isn't an integer");
        }
        return value.data;
    }

    private int dimension(int id) {
        Arsc.Value value = value(id);
        if (value.type != Arsc.TYPE_DIMENSION) throw new NotFoundException("Resource ID #0x" + Integer.toHexString(id) + " isn't a dimension");
        return value.data;
    }

    public float getDimension(int id) { return TypedValue.complexToDimension(dimension(id), metrics); }
    public int getDimensionPixelSize(int id) { return TypedValue.complexToDimensionPixelSize(dimension(id), metrics); }
    public int getDimensionPixelOffset(int id) { return TypedValue.complexToDimensionPixelOffset(dimension(id), metrics); }

    /** A drawable: a colour's is a ColorDrawable; any other is inert (nothing is drawn). */
    public Drawable getDrawable(int id) {
        Arsc.Value value = value(id);
        if (value.type >= Arsc.TYPE_FIRST_COLOR_INT && value.type <= Arsc.TYPE_LAST_COLOR_INT) return new ColorDrawable(value.data);
        return new Drawable();
    }

    public Drawable getDrawable(int id, Theme theme) { return getDrawable(id); }
    public XmlResourceParser getLayout(int id) { return xml(id); }
    public XmlResourceParser getXml(int id) { return xml(id); }
    public XmlResourceParser getAnimation(int id) { return xml(id); }

    private byte[] fileBytes(int id) {
        Arsc.Value value = value(id);
        if (value.string == null || file == null) throw new NotFoundException("Resource ID #0x" + Integer.toHexString(id) + " isn't a file");
        try (ZipFile zip = new ZipFile(file)) {
            ZipEntry entry = zip.getEntry(value.string);
            if (entry == null) throw new NotFoundException("File " + value.string + " from resource ID #0x" + Integer.toHexString(id));
            try (InputStream in = zip.getInputStream(entry)) {
                return in.readAllBytes();
            }
        } catch (IOException e) {
            throw new NotFoundException("File " + value.string + " from resource ID #0x" + Integer.toHexString(id), e);
        }
    }

    private XmlResourceParser xml(int id) {
        Axml parser = new Axml(fileBytes(id));
        parser.resources = this;
        parser.classLoader = classLoader;
        return parser;
    }

    public InputStream openRawResource(int id) { return new ByteArrayInputStream(fileBytes(id)); }

    /** An id by name: "package:type/entry", "type/entry", or [name] of [defType], in the extension's own package. */
    public int getIdentifier(String name, String defType, String defPackage) {
        if (table == null || name == null) return 0;
        String type = defType;
        String entry = name;
        String pkg = defPackage;
        int colon = entry.indexOf(':');
        if (colon >= 0) {
            pkg = entry.substring(0, colon);
            entry = entry.substring(colon + 1);
        }
        int slash = entry.indexOf('/');
        if (slash >= 0) {
            type = entry.substring(0, slash);
            entry = entry.substring(slash + 1);
        }
        if (type == null || (pkg != null && !pkg.isEmpty() && !pkg.equals(table.packageName()))) return 0;
        return table.identifier(type, entry);
    }

    public String getResourceName(int id) {
        Arsc.Entry entry = entry(id);
        return table.packageName() + ":" + entry.type + "/" + entry.name;
    }

    public String getResourcePackageName(int id) {
        entry(id);
        return table.packageName();
    }

    public String getResourceTypeName(int id) { return entry(id).type; }
    public String getResourceEntryName(int id) { return entry(id).name; }
}
