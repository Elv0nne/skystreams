package android.view;

/** A key press: the stand-ins only pass the ones the engine sends (Back). */
public class KeyEvent {
    public static final int ACTION_DOWN = 0;
    public static final int ACTION_UP = 1;
    public static final int KEYCODE_BACK = 4;
    public static final int KEYCODE_DPAD_UP = 19;
    public static final int KEYCODE_DPAD_DOWN = 20;
    public static final int KEYCODE_DPAD_LEFT = 21;
    public static final int KEYCODE_DPAD_RIGHT = 22;
    public static final int KEYCODE_DPAD_CENTER = 23;
    public static final int KEYCODE_TAB = 61;
    public static final int KEYCODE_ENTER = 66;
    public static final int KEYCODE_SEARCH = 84;
    public static final int KEYCODE_ESCAPE = 111;

    private final long downTime;
    private final long eventTime;
    private final int action;
    private final int code;
    private final int repeat;

    public KeyEvent(int action, int code) {
        this(0, 0, action, code, 0);
    }

    public KeyEvent(long downTime, long eventTime, int action, int code, int repeat) {
        this.downTime = downTime;
        this.eventTime = eventTime;
        this.action = action;
        this.code = code;
        this.repeat = repeat;
    }

    public final int getAction() { return action; }
    public final int getKeyCode() { return code; }
    public final int getRepeatCount() { return repeat; }
    public final long getDownTime() { return downTime; }
    public final long getEventTime() { return eventTime; }
    public final int getMetaState() { return 0; }
    public final boolean isShiftPressed() { return false; }
    public final boolean isCtrlPressed() { return false; }
    @Override public String toString() { return "KeyEvent { action=" + action + ", keyCode=" + code + " }"; }
}
