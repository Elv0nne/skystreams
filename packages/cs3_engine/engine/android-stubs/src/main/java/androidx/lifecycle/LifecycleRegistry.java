package androidx.lifecycle;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * A lifecycle its owner moves. Each observer hears every step between its state and the new one: going
 * down the newest observer first, going up the oldest first, as Android's. One added late catches up at
 * once, and a destroyed lifecycle lets its observers go. Stand-in lifecycles move on the main thread.
 * Observers using Android's deprecated @OnLifecycleEvent annotations hear nothing.
 */
public class LifecycleRegistry extends Lifecycle {
    private final LifecycleOwner owner;
    private final Map<LifecycleObserver, ObserverWithState> observers = new LinkedHashMap<>();
    private State state = State.INITIALIZED;
    private boolean syncing;
    private boolean again;

    public LifecycleRegistry(LifecycleOwner provider) {
        this.owner = provider;
    }

    @Deprecated
    public void markState(State state) {
        setCurrentState(state);
    }

    public void setCurrentState(State state) {
        moveTo(state);
    }

    public void handleLifecycleEvent(Event event) {
        moveTo(event.getTargetState());
    }

    @Override public State getCurrentState() { return state; }

    public int getObserverCount() { return observers.size(); }

    @Override public void addObserver(LifecycleObserver observer) {
        ObserverWithState added = new ObserverWithState(observer, state == State.DESTROYED ? State.DESTROYED : State.INITIALIZED);
        if (observers.putIfAbsent(observer, added) != null) return;
        while (added.state.compareTo(state) < 0 && observers.get(observer) == added) added.dispatch(owner, Event.upFrom(added.state));
    }

    @Override public void removeObserver(LifecycleObserver observer) {
        observers.remove(observer);
    }

    private void moveTo(State next) {
        if (state == next) return;
        if (state == State.INITIALIZED && next == State.DESTROYED) {
            throw new IllegalStateException("State must be at least CREATED to move to DESTROYED, but was INITIALIZED in component " + owner);
        }
        state = next;
        // An observer that moves the lifecycle again restarts the walk, toward the newest state.
        if (syncing) {
            again = true;
            return;
        }
        syncing = true;
        try {
            do {
                again = false;
                sync();
            } while (again);
        } finally {
            syncing = false;
        }
        if (state == State.DESTROYED) observers.clear();
    }

    private void sync() {
        List<ObserverWithState> all = new ArrayList<>(observers.values());
        for (int i = all.size() - 1; i >= 0 && !again; i--) {
            ObserverWithState observer = all.get(i);
            while (!again && observer.state.compareTo(state) > 0 && observers.get(observer.observer) == observer) {
                Event event = Event.downFrom(observer.state);
                if (event == null) {
                    observer.state = state;
                    break;
                }
                observer.dispatch(owner, event);
            }
        }
        for (ObserverWithState observer : all) {
            while (!again && observer.state.compareTo(state) < 0 && observers.get(observer.observer) == observer) {
                observer.dispatch(owner, Event.upFrom(observer.state));
            }
        }
    }

    private static final class ObserverWithState {
        final LifecycleObserver observer;
        State state;

        ObserverWithState(LifecycleObserver observer, State state) {
            this.observer = observer;
            this.state = state;
        }

        void dispatch(LifecycleOwner owner, Event event) {
            State next = event.getTargetState();
            if (next.compareTo(state) < 0) state = next;
            if (observer instanceof DefaultLifecycleObserver) {
                DefaultLifecycleObserver steps = (DefaultLifecycleObserver) observer;
                switch (event) {
                    case ON_CREATE: steps.onCreate(owner); break;
                    case ON_START: steps.onStart(owner); break;
                    case ON_RESUME: steps.onResume(owner); break;
                    case ON_PAUSE: steps.onPause(owner); break;
                    case ON_STOP: steps.onStop(owner); break;
                    case ON_DESTROY: steps.onDestroy(owner); break;
                    default: break;
                }
            }
            if (observer instanceof LifecycleEventObserver) ((LifecycleEventObserver) observer).onStateChanged(owner, event);
            state = next;
        }
    }
}
