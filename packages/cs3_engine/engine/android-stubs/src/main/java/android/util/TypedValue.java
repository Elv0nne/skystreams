package android.util;

import dev.akash.cs3engine.stubs.Arsc;
import dev.akash.cs3engine.stubs.Axml;

/** A resource value, and Android's dimension arithmetic at the stand-ins' density. */
public class TypedValue {
    public static final int TYPE_NULL = 0x00;
    public static final int TYPE_REFERENCE = 0x01;
    public static final int TYPE_ATTRIBUTE = 0x02;
    public static final int TYPE_STRING = 0x03;
    public static final int TYPE_FLOAT = 0x04;
    public static final int TYPE_DIMENSION = 0x05;
    public static final int TYPE_FRACTION = 0x06;
    public static final int TYPE_FIRST_INT = 0x10;
    public static final int TYPE_INT_DEC = 0x10;
    public static final int TYPE_INT_HEX = 0x11;
    public static final int TYPE_INT_BOOLEAN = 0x12;
    public static final int TYPE_FIRST_COLOR_INT = 0x1c;
    public static final int TYPE_INT_COLOR_ARGB8 = 0x1c;
    public static final int TYPE_INT_COLOR_RGB8 = 0x1d;
    public static final int TYPE_INT_COLOR_ARGB4 = 0x1e;
    public static final int TYPE_INT_COLOR_RGB4 = 0x1f;
    public static final int TYPE_LAST_COLOR_INT = 0x1f;
    public static final int TYPE_LAST_INT = 0x1f;
    public static final int COMPLEX_UNIT_SHIFT = 0;
    public static final int COMPLEX_UNIT_MASK = 0xf;
    public static final int COMPLEX_UNIT_PX = 0;
    public static final int COMPLEX_UNIT_DIP = 1;
    public static final int COMPLEX_UNIT_SP = 2;
    public static final int COMPLEX_UNIT_PT = 3;
    public static final int COMPLEX_UNIT_IN = 4;
    public static final int COMPLEX_UNIT_MM = 5;

    public int type;
    public CharSequence string;
    public int data;
    public int assetCookie;
    public int resourceId;
    public int changingConfigurations;
    public int density;

    public static float applyDimension(int unit, float value, DisplayMetrics metrics) {
        switch (unit) {
            case COMPLEX_UNIT_PX: return value;
            case COMPLEX_UNIT_DIP: return value * metrics.density;
            case COMPLEX_UNIT_SP: return value * metrics.scaledDensity;
            case COMPLEX_UNIT_PT: return value * metrics.xdpi * (1.0f / 72);
            case COMPLEX_UNIT_IN: return value * metrics.xdpi;
            case COMPLEX_UNIT_MM: return value * metrics.xdpi * (1.0f / 25.4f);
            default: return 0;
        }
    }

    public static float complexToFloat(int complex) {
        return Arsc.complexToFloat(complex);
    }

    public static float complexToDimension(int data, DisplayMetrics metrics) {
        return applyDimension(data & COMPLEX_UNIT_MASK, complexToFloat(data), metrics);
    }

    public static int complexToDimensionPixelOffset(int data, DisplayMetrics metrics) {
        return (int) complexToDimension(data, metrics);
    }

    /** As Android: rounded, and never zero for a size that isn't (a hairline is a pixel). */
    public static int complexToDimensionPixelSize(int data, DisplayMetrics metrics) {
        float value = complexToFloat(data);
        float size = applyDimension(data & COMPLEX_UNIT_MASK, value, metrics);
        int rounded = (int) (size >= 0 ? size + 0.5f : size - 0.5f);
        if (rounded != 0) return rounded;
        if (value == 0) return 0;
        return value > 0 ? 1 : -1;
    }

    public final float getFloat() { return Float.intBitsToFloat(data); }
    public float getDimension(DisplayMetrics metrics) { return complexToDimension(data, metrics); }

    public final CharSequence coerceToString() {
        return type == TYPE_STRING ? string : Axml.coerce(type, data);
    }
}
