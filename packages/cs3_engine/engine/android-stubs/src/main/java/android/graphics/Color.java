package android.graphics;

import java.util.HashMap;
import java.util.Locale;
import java.util.Map;

/** Colour arithmetic and parsing, as Android's. */
public class Color {
    public static final int BLACK = 0xFF000000;
    public static final int DKGRAY = 0xFF444444;
    public static final int GRAY = 0xFF888888;
    public static final int LTGRAY = 0xFFCCCCCC;
    public static final int WHITE = 0xFFFFFFFF;
    public static final int RED = 0xFFFF0000;
    public static final int GREEN = 0xFF00FF00;
    public static final int BLUE = 0xFF0000FF;
    public static final int YELLOW = 0xFFFFFF00;
    public static final int CYAN = 0xFF00FFFF;
    public static final int MAGENTA = 0xFFFF00FF;
    public static final int TRANSPARENT = 0;

    private static final Map<String, Integer> NAMES = new HashMap<>();

    static {
        NAMES.put("black", BLACK);
        NAMES.put("darkgray", DKGRAY);
        NAMES.put("gray", GRAY);
        NAMES.put("lightgray", LTGRAY);
        NAMES.put("white", WHITE);
        NAMES.put("red", RED);
        NAMES.put("green", GREEN);
        NAMES.put("blue", BLUE);
        NAMES.put("yellow", YELLOW);
        NAMES.put("cyan", CYAN);
        NAMES.put("magenta", MAGENTA);
        NAMES.put("aqua", 0xFF00FFFF);
        NAMES.put("fuchsia", 0xFFFF00FF);
        NAMES.put("darkgrey", DKGRAY);
        NAMES.put("grey", GRAY);
        NAMES.put("lightgrey", LTGRAY);
        NAMES.put("lime", 0xFF00FF00);
        NAMES.put("maroon", 0xFF800000);
        NAMES.put("navy", 0xFF000080);
        NAMES.put("olive", 0xFF808000);
        NAMES.put("purple", 0xFF800080);
        NAMES.put("silver", 0xFFC0C0C0);
        NAMES.put("teal", 0xFF008080);
    }

    public static int alpha(int color) { return color >>> 24; }
    public static int red(int color) { return (color >> 16) & 0xFF; }
    public static int green(int color) { return (color >> 8) & 0xFF; }
    public static int blue(int color) { return color & 0xFF; }
    public static int rgb(int red, int green, int blue) { return 0xFF000000 | (red << 16) | (green << 8) | blue; }
    public static int argb(int alpha, int red, int green, int blue) { return (alpha << 24) | (red << 16) | (green << 8) | blue; }

    public static int rgb(float red, float green, float blue) {
        return argb(1f, red, green, blue);
    }

    public static int argb(float alpha, float red, float green, float blue) {
        return ((int) (alpha * 255.0f + 0.5f) << 24) | ((int) (red * 255.0f + 0.5f) << 16) | ((int) (green * 255.0f + 0.5f) << 8) | (int) (blue * 255.0f + 0.5f);
    }

    /** "#RRGGBB", "#AARRGGBB", or one of Android's colour names; anything else throws. */
    public static int parseColor(String colorString) {
        if (colorString.startsWith("#")) {
            long color;
            try {
                color = Long.parseLong(colorString.substring(1), 16);
            } catch (NumberFormatException e) {
                throw new IllegalArgumentException("Unknown color");
            }
            if (colorString.length() == 7) {
                color |= 0x00000000FF000000L;
            } else if (colorString.length() != 9) {
                throw new IllegalArgumentException("Unknown color");
            }
            return (int) color;
        }
        Integer color = NAMES.get(colorString.toLowerCase(Locale.ROOT));
        if (color == null) throw new IllegalArgumentException("Unknown color");
        return color;
    }
}
