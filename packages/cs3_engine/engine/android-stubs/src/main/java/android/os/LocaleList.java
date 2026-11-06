package android.os;

import dev.akash.cs3engine.stubs.StubEnv;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/** A list of locales: the stand-ins' default is the app's language. */
public final class LocaleList {
    private final Locale[] list;

    public LocaleList(Locale... list) {
        this.list = list.clone();
    }

    public static LocaleList getDefault() { return new LocaleList(Locale.forLanguageTag(StubEnv.language())); }
    public static LocaleList getAdjustedDefault() { return getDefault(); }
    public static LocaleList getEmptyLocaleList() { return new LocaleList(); }

    public static LocaleList forLanguageTags(String list) {
        if (list == null || list.isEmpty()) return getEmptyLocaleList();
        List<Locale> locales = new ArrayList<>();
        for (String tag : list.split(",")) locales.add(Locale.forLanguageTag(tag.trim()));
        return new LocaleList(locales.toArray(new Locale[0]));
    }

    public Locale get(int index) { return index >= 0 && index < list.length ? list[index] : null; }
    public int size() { return list.length; }
    public boolean isEmpty() { return list.length == 0; }

    public int indexOf(Locale locale) {
        for (int i = 0; i < list.length; i++) if (list[i].equals(locale)) return i;
        return -1;
    }

    public String toLanguageTags() {
        StringBuilder out = new StringBuilder();
        for (Locale locale : list) out.append(out.length() == 0 ? "" : ",").append(locale.toLanguageTag());
        return out.toString();
    }

    @Override public String toString() { return "[" + toLanguageTags() + "]"; }
}
