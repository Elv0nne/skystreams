package androidx.lifecycle;

import java.util.concurrent.atomic.AtomicReference;

/** Android's lifecycle: states, the events between them, and observers that hear them. */
public abstract class Lifecycle {
    /** The coroutine scope LifecycleKt gives this lifecycle, made once. */
    final AtomicReference<Object> scope = new AtomicReference<>();

    public Lifecycle() {}

    public abstract void addObserver(LifecycleObserver observer);

    public abstract void removeObserver(LifecycleObserver observer);

    public abstract State getCurrentState();

    public enum Event {
        ON_CREATE, ON_START, ON_RESUME, ON_PAUSE, ON_STOP, ON_DESTROY, ON_ANY;

        public static final Companion Companion = new Companion();

        /** The state this event leads to. */
        public final State getTargetState() {
            switch (this) {
                case ON_CREATE:
                case ON_STOP:
                    return State.CREATED;
                case ON_START:
                case ON_PAUSE:
                    return State.STARTED;
                case ON_RESUME:
                    return State.RESUMED;
                case ON_DESTROY:
                    return State.DESTROYED;
                default:
                    throw new IllegalArgumentException(this + " has no target state");
            }
        }

        /** The event that leaves [state] going down, or null. */
        public static Event downFrom(State state) {
            switch (state) {
                case CREATED: return ON_DESTROY;
                case STARTED: return ON_STOP;
                case RESUMED: return ON_PAUSE;
                default: return null;
            }
        }

        /** The event that reaches [state] going down, or null. */
        public static Event downTo(State state) {
            switch (state) {
                case DESTROYED: return ON_DESTROY;
                case CREATED: return ON_STOP;
                case STARTED: return ON_PAUSE;
                default: return null;
            }
        }

        /** The event that leaves [state] going up, or null. */
        public static Event upFrom(State state) {
            switch (state) {
                case INITIALIZED: return ON_CREATE;
                case CREATED: return ON_START;
                case STARTED: return ON_RESUME;
                default: return null;
            }
        }

        /** The event that reaches [state] going up, or null. */
        public static Event upTo(State state) {
            switch (state) {
                case CREATED: return ON_CREATE;
                case STARTED: return ON_START;
                case RESUMED: return ON_RESUME;
                default: return null;
            }
        }

        /** Kotlin callers reach the four through the companion. */
        public static final class Companion {
            private Companion() {}

            public final Event downFrom(State state) { return Event.downFrom(state); }
            public final Event downTo(State state) { return Event.downTo(state); }
            public final Event upFrom(State state) { return Event.upFrom(state); }
            public final Event upTo(State state) { return Event.upTo(state); }
        }
    }

    public enum State {
        DESTROYED, INITIALIZED, CREATED, STARTED, RESUMED;

        public final boolean isAtLeast(State state) {
            return compareTo(state) >= 0;
        }
    }
}
