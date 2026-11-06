package android.widget;

import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.drawable.Drawable;
import android.net.Uri;
import android.util.AttributeSet;
import android.view.View;
import dev.akash.cs3engine.stubs.LayoutAttributes;

/** A stand-in image: its drawable or resource, and how it scales. Nothing is drawn. */
public class ImageView extends View {
    public enum ScaleType { MATRIX, FIT_XY, FIT_START, FIT_CENTER, FIT_END, CENTER, CENTER_CROP, CENTER_INSIDE }

    private Drawable drawable;
    private int resource;
    private Uri uri;
    private ScaleType scaleType = ScaleType.FIT_CENTER;

    public ImageView(Context context) {
        this(context, null);
    }

    public ImageView(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public ImageView(Context context, AttributeSet attrs, int defStyleAttr) {
        this(context, attrs, defStyleAttr, 0);
    }

    public ImageView(Context context, AttributeSet attrs, int defStyleAttr, int defStyleRes) {
        super(context, attrs, defStyleAttr, defStyleRes);
        LayoutAttributes.image(this, attrs);
    }

    public void setImageDrawable(Drawable drawable) {
        this.drawable = drawable;
        this.resource = 0;
    }

    public Drawable getDrawable() { return drawable; }

    public void setImageResource(int resId) {
        this.resource = resId;
        this.drawable = null;
    }

    public void setImageURI(Uri uri) { this.uri = uri; }
    public void setScaleType(ScaleType scaleType) { if (scaleType == null) throw new NullPointerException(); this.scaleType = scaleType; }
    public ScaleType getScaleType() { return scaleType; }
    public void setImageTintList(ColorStateList tint) {}
    public void setAdjustViewBounds(boolean adjustViewBounds) {}
}
