package android.content.res;

/** Colours by view state: a stand-in uses the default one. */
public class ColorStateList {
    private final int[][] states;
    private final int[] colors;

    public ColorStateList(int[][] states, int[] colors) {
        this.states = states;
        this.colors = colors;
    }

    public static ColorStateList valueOf(int color) {
        return new ColorStateList(new int[][] {new int[0]}, new int[] {color});
    }

    /** The colour for no particular state: the empty state set's, else the first. */
    public int getDefaultColor() {
        for (int i = 0; i < states.length && i < colors.length; i++) if (states[i].length == 0) return colors[i];
        return colors.length > 0 ? colors[0] : 0;
    }

    public int getColorForState(int[] stateSet, int defaultColor) { return colors.length > 0 ? getDefaultColor() : defaultColor; }
    public boolean isStateful() { return states.length > 1; }

    public ColorStateList withAlpha(int alpha) {
        int[] faded = new int[colors.length];
        for (int i = 0; i < colors.length; i++) faded[i] = (colors[i] & 0xFFFFFF) | (alpha << 24);
        return new ColorStateList(states, faded);
    }
}
