package android.graphics;

/** A paint's flags, size, colour and typeface: what text views read back. Nothing is measured. */
public class Paint {
    public static final int ANTI_ALIAS_FLAG = 0x01;
    public static final int FILTER_BITMAP_FLAG = 0x02;
    public static final int DITHER_FLAG = 0x04;
    public static final int UNDERLINE_TEXT_FLAG = 0x08;
    public static final int STRIKE_THRU_TEXT_FLAG = 0x10;
    public static final int FAKE_BOLD_TEXT_FLAG = 0x20;
    public static final int LINEAR_TEXT_FLAG = 0x40;
    public static final int SUBPIXEL_TEXT_FLAG = 0x80;

    private int flags;
    private float textSize = 12f;
    private int color = 0xFF000000;
    private int alpha = 0xFF;
    private Typeface typeface;

    public Paint() {}

    public Paint(int flags) {
        this.flags = flags;
    }

    public Paint(Paint paint) {
        set(paint);
    }

    public void set(Paint src) {
        flags = src.flags;
        textSize = src.textSize;
        color = src.color;
        alpha = src.alpha;
        typeface = src.typeface;
    }

    public int getFlags() { return flags; }
    public void setFlags(int flags) { this.flags = flags; }
    private void flag(int flag, boolean on) { flags = on ? flags | flag : flags & ~flag; }
    public final boolean isAntiAlias() { return (flags & ANTI_ALIAS_FLAG) != 0; }
    public void setAntiAlias(boolean aa) { flag(ANTI_ALIAS_FLAG, aa); }
    public final boolean isUnderlineText() { return (flags & UNDERLINE_TEXT_FLAG) != 0; }
    public void setUnderlineText(boolean underlineText) { flag(UNDERLINE_TEXT_FLAG, underlineText); }
    public final boolean isStrikeThruText() { return (flags & STRIKE_THRU_TEXT_FLAG) != 0; }
    public void setStrikeThruText(boolean strikeThruText) { flag(STRIKE_THRU_TEXT_FLAG, strikeThruText); }
    public final boolean isFakeBoldText() { return (flags & FAKE_BOLD_TEXT_FLAG) != 0; }
    public void setFakeBoldText(boolean fakeBoldText) { flag(FAKE_BOLD_TEXT_FLAG, fakeBoldText); }
    public float getTextSize() { return textSize; }
    public void setTextSize(float textSize) { this.textSize = textSize; }
    public int getColor() { return color; }
    public void setColor(int color) { this.color = color; this.alpha = color >>> 24; }
    public int getAlpha() { return alpha; }
    public void setAlpha(int a) { alpha = a; }
    public Typeface getTypeface() { return typeface; }
    public Typeface setTypeface(Typeface typeface) { this.typeface = typeface; return typeface; }
    public float measureText(String text) { return 0f; }
    public float measureText(CharSequence text, int start, int end) { return 0f; }
}
