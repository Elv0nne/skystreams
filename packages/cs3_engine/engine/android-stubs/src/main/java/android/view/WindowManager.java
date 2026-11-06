package android.view;

/** What adds windows; a window's parameters. Stand-in windows are the engine's: nothing is added here. */
public interface WindowManager extends ViewManager {
    void removeViewImmediate(View view);

    class LayoutParams extends ViewGroup.LayoutParams {
        public static final int TYPE_APPLICATION = 2;
        public static final int FLAG_NOT_FOCUSABLE = 0x00000008;
        public static final int FLAG_NOT_TOUCHABLE = 0x00000010;
        public static final int FLAG_KEEP_SCREEN_ON = 0x00000080;
        public static final int FLAG_FULLSCREEN = 0x00000400;

        public int flags;
        public int type;
        public int gravity;
        public int softInputMode;
        public int windowAnimations;
        public int x;
        public int y;
        public int format;
        public float alpha = 1f;
        public float dimAmount = 1f;
        public float horizontalMargin;
        public float verticalMargin;
        public float screenBrightness = -1f;
        public String packageName;
        private CharSequence title = "";

        public LayoutParams() {
            super(MATCH_PARENT, MATCH_PARENT);
            type = TYPE_APPLICATION;
        }

        public LayoutParams(int type) {
            this();
            this.type = type;
        }

        public LayoutParams(int type, int flags) {
            this(type);
            this.flags = flags;
        }

        public LayoutParams(int w, int h, int type, int flags, int format) {
            super(w, h);
            this.type = type;
            this.flags = flags;
            this.format = format;
        }

        public final void setTitle(CharSequence title) { this.title = title == null ? "" : title; }
        public final CharSequence getTitle() { return title; }
    }
}
