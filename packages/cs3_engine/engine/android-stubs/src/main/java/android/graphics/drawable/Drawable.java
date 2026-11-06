package android.graphics.drawable;

import android.content.res.ColorStateList;

/** A drawable: nothing is drawn; it keeps its alpha and visibility, and mutating gives itself. */
public class Drawable {
    private int alpha = 0xFF;
    private boolean visible = true;

    public Drawable mutate() { return this; }
    public int getAlpha() { return alpha; }
    public void setAlpha(int alpha) { this.alpha = alpha; }
    public void setTint(int tintColor) {}
    public void setTintList(ColorStateList tint) {}
    public void setBounds(int left, int top, int right, int bottom) {}
    public int getIntrinsicWidth() { return -1; }
    public int getIntrinsicHeight() { return -1; }
    public int getMinimumWidth() { return 0; }
    public int getMinimumHeight() { return 0; }
    public int getOpacity() { return -3; }
    public void invalidateSelf() {}

    public boolean setVisible(boolean visible, boolean restart) {
        boolean changed = this.visible != visible;
        this.visible = visible;
        return changed;
    }

    public final boolean isVisible() { return visible; }
}
