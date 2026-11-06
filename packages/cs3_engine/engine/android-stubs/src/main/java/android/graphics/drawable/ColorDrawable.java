package android.graphics.drawable;

/** A drawable of one colour. */
public class ColorDrawable extends Drawable {
    private int color;

    public ColorDrawable() {}

    public ColorDrawable(int color) {
        this.color = color;
    }

    public int getColor() { return color; }
    public void setColor(int color) { this.color = color; }
}
