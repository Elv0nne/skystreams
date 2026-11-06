package android.graphics;

/** A typeface's style and weight: all a stand-in keeps (a sheet's text is bold or not). */
public class Typeface {
    public static final int NORMAL = 0;
    public static final int BOLD = 1;
    public static final int ITALIC = 2;
    public static final int BOLD_ITALIC = 3;

    public static final Typeface DEFAULT = new Typeface(NORMAL, 400);
    public static final Typeface DEFAULT_BOLD = new Typeface(BOLD, 700);
    public static final Typeface SANS_SERIF = new Typeface(NORMAL, 400);
    public static final Typeface SERIF = new Typeface(NORMAL, 400);
    public static final Typeface MONOSPACE = new Typeface(NORMAL, 400);

    private final int style;
    private final int weight;

    private Typeface(int style, int weight) {
        this.style = style;
        this.weight = weight;
    }

    public static Typeface create(Typeface family, int style) {
        return defaultFromStyle(style);
    }

    public static Typeface create(String familyName, int style) {
        return defaultFromStyle(style);
    }

    public static Typeface create(Typeface family, int weight, boolean italic) {
        return new Typeface((weight >= 600 ? BOLD : NORMAL) | (italic ? ITALIC : NORMAL), weight);
    }

    public static Typeface defaultFromStyle(int style) {
        return new Typeface(style & BOLD_ITALIC, (style & BOLD) != 0 ? 700 : 400);
    }

    public int getStyle() { return style; }
    public final boolean isBold() { return (style & BOLD) != 0; }
    public final boolean isItalic() { return (style & ITALIC) != 0; }
    public int getWeight() { return weight; }
}
