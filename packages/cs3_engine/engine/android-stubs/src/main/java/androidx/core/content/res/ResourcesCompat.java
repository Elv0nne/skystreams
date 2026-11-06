package androidx.core.content.res;

import android.content.res.Resources;
import android.graphics.drawable.Drawable;

/**
 * AndroidX's resource helpers, as far as extensions use them: 35 of MegaRepo's take their icons from getDrawable,
 * which the framework index answered with null. The fill gives its other members as no-ops.
 */
public final class ResourcesCompat {
    private ResourcesCompat() {}

    public static Drawable getDrawable(Resources res, int id, Resources.Theme theme) throws Resources.NotFoundException {
        return res.getDrawable(id, theme);
    }
}
