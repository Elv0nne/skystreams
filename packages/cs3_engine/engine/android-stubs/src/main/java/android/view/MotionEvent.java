package android.view;

/** A touch, as the engine's actions would make one; the stand-ins take taps as actions, not touches. */
public final class MotionEvent {
    public static final int ACTION_MASK = 0xff;
    public static final int ACTION_DOWN = 0;
    public static final int ACTION_UP = 1;
    public static final int ACTION_MOVE = 2;
    public static final int ACTION_CANCEL = 3;
    public static final int ACTION_OUTSIDE = 4;

    private final long downTime;
    private final long eventTime;
    private final int action;
    private float x;
    private float y;
    private final int metaState;

    private MotionEvent(long downTime, long eventTime, int action, float x, float y, int metaState) {
        this.downTime = downTime;
        this.eventTime = eventTime;
        this.action = action;
        this.x = x;
        this.y = y;
        this.metaState = metaState;
    }

    public static MotionEvent obtain(long downTime, long eventTime, int action, float x, float y, int metaState) {
        return new MotionEvent(downTime, eventTime, action, x, y, metaState);
    }

    public static MotionEvent obtain(MotionEvent other) {
        return new MotionEvent(other.downTime, other.eventTime, other.action, other.x, other.y, other.metaState);
    }

    public final int getAction() { return action; }
    public final int getActionMasked() { return action & ACTION_MASK; }
    public final float getX() { return x; }
    public final float getY() { return y; }
    public final float getRawX() { return x; }
    public final float getRawY() { return y; }
    public final long getDownTime() { return downTime; }
    public final long getEventTime() { return eventTime; }
    public final int getMetaState() { return metaState; }
    public final int getPointerCount() { return 1; }

    public final void setLocation(float x, float y) {
        this.x = x;
        this.y = y;
    }

    public final void recycle() {}
}
