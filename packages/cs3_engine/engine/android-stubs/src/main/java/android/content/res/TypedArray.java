package android.content.res;

import android.graphics.drawable.Drawable;
import android.util.TypedValue;

/** Styled attributes: none are read off the JVM, so each getter gives what Android gives for one that isn't set. */
public class TypedArray implements AutoCloseable {
    private final int length;

    public TypedArray(int length) {
        this.length = length;
    }

    public int length() { return length; }
    public int getIndexCount() { return 0; }
    public int getIndex(int at) { return at; }
    public boolean hasValue(int index) { return false; }
    public boolean hasValueOrEmpty(int index) { return false; }
    public CharSequence getText(int index) { return null; }
    public String getString(int index) { return null; }
    public String getNonResourceString(int index) { return null; }
    public boolean getBoolean(int index, boolean defValue) { return defValue; }
    public int getInt(int index, int defValue) { return defValue; }
    public float getFloat(int index, float defValue) { return defValue; }
    public int getColor(int index, int defValue) { return defValue; }
    public ColorStateList getColorStateList(int index) { return null; }
    public int getInteger(int index, int defValue) { return defValue; }
    public float getDimension(int index, float defValue) { return defValue; }
    public int getDimensionPixelOffset(int index, int defValue) { return defValue; }
    public int getDimensionPixelSize(int index, int defValue) { return defValue; }
    public int getLayoutDimension(int index, int defValue) { return defValue; }
    public float getFraction(int index, int base, int pbase, float defValue) { return defValue; }
    public int getResourceId(int index, int defValue) { return defValue; }
    public Drawable getDrawable(int index) { return null; }
    public CharSequence[] getTextArray(int index) { return null; }
    public boolean getValue(int index, TypedValue outValue) { return false; }
    public int getType(int index) { return TypedValue.TYPE_NULL; }
    public void recycle() {}
    @Override public void close() {}
}
