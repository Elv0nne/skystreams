package android.content.res;

import android.os.LocaleList;
import dev.akash.cs3engine.stubs.StubEnv;
import java.util.Locale;

/** The stand-ins' device: a dark, portrait phone (DisplayMetrics' 1080×2340 at density 2) in the app's language. */
public final class Configuration {
    public static final int UI_MODE_TYPE_MASK = 0x0f;
    public static final int UI_MODE_TYPE_NORMAL = 0x01;
    public static final int UI_MODE_TYPE_TELEVISION = 0x04;
    public static final int UI_MODE_NIGHT_MASK = 0x30;
    public static final int UI_MODE_NIGHT_NO = 0x10;
    public static final int UI_MODE_NIGHT_YES = 0x20;
    public static final int ORIENTATION_PORTRAIT = 1;
    public static final int ORIENTATION_LANDSCAPE = 2;

    public float fontScale = 1f;
    public int uiMode = UI_MODE_TYPE_NORMAL | UI_MODE_NIGHT_YES;
    public int orientation = ORIENTATION_PORTRAIT;
    public int densityDpi = 320;
    public int screenWidthDp = 540;
    public int screenHeightDp = 1170;
    public int smallestScreenWidthDp = 540;
    @Deprecated
    public Locale locale;
    private LocaleList locales;

    public Configuration() {
        setLocale(Locale.forLanguageTag(StubEnv.language()));
    }

    public Configuration(Configuration o) {
        setTo(o);
    }

    public void setTo(Configuration o) {
        fontScale = o.fontScale;
        uiMode = o.uiMode;
        orientation = o.orientation;
        densityDpi = o.densityDpi;
        screenWidthDp = o.screenWidthDp;
        screenHeightDp = o.screenHeightDp;
        smallestScreenWidthDp = o.smallestScreenWidthDp;
        locale = o.locale;
        locales = o.locales;
    }

    public LocaleList getLocales() { return locales; }

    public void setLocales(LocaleList locales) {
        this.locales = locales == null || locales.isEmpty() ? LocaleList.getDefault() : locales;
        this.locale = this.locales.get(0);
    }

    public void setLocale(Locale loc) {
        setLocales(loc == null ? null : new LocaleList(loc));
    }

    public boolean isNightModeActive() { return (uiMode & UI_MODE_NIGHT_MASK) == UI_MODE_NIGHT_YES; }
    public int getLayoutDirection() { return 0; }
}
