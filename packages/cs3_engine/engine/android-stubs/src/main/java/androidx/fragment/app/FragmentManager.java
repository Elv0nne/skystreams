package androidx.fragment.app;

import android.app.Activity;
import android.content.Context;
import android.os.Bundle;
import android.view.View;
import android.view.ViewGroup;
import dev.akash.cs3engine.stubs.MainThread;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * A stand-in fragment manager: an activity's (resumed, as the engine's activity always is) or a fragment's
 * own, which follows its fragment. Commits run after the current main-thread task, in order; commitNow at
 * once. Each operation moves its fragments through their lifecycles as Android's does, and a back-stack
 * entry keeps the fragments it removed created, without views, until it's popped.
 */
public abstract class FragmentManager {
    public static final String TAG = "FragmentManager";
    public static final int POP_BACK_STACK_INCLUSIVE = 1;

    /** Hears the fragments' steps; a recursive one hears its manager's children's fragments too. */
    public abstract static class FragmentLifecycleCallbacks {
        public FragmentLifecycleCallbacks() {}

        public void onFragmentPreAttached(FragmentManager fm, Fragment f, Context context) {}
        public void onFragmentAttached(FragmentManager fm, Fragment f, Context context) {}
        public void onFragmentPreCreated(FragmentManager fm, Fragment f, Bundle savedInstanceState) {}
        public void onFragmentCreated(FragmentManager fm, Fragment f, Bundle savedInstanceState) {}
        @Deprecated public void onFragmentActivityCreated(FragmentManager fm, Fragment f, Bundle savedInstanceState) {}
        public void onFragmentViewCreated(FragmentManager fm, Fragment f, View v, Bundle savedInstanceState) {}
        public void onFragmentStarted(FragmentManager fm, Fragment f) {}
        public void onFragmentResumed(FragmentManager fm, Fragment f) {}
        public void onFragmentPaused(FragmentManager fm, Fragment f) {}
        public void onFragmentStopped(FragmentManager fm, Fragment f) {}
        public void onFragmentSaveInstanceState(FragmentManager fm, Fragment f, Bundle outState) {}
        public void onFragmentViewDestroyed(FragmentManager fm, Fragment f) {}
        public void onFragmentDestroyed(FragmentManager fm, Fragment f) {}
        public void onFragmentDetached(FragmentManager fm, Fragment f) {}
    }

    private interface Step {
        void tell(FragmentLifecycleCallbacks callbacks, FragmentManager manager);
    }

    private static final class Registered {
        final FragmentLifecycleCallbacks callbacks;
        final boolean recursive;

        Registered(FragmentLifecycleCallbacks callbacks, boolean recursive) {
            this.callbacks = callbacks;
            this.recursive = recursive;
        }
    }

    final Context host;
    final Fragment parent;
    int state;
    private volatile boolean destroyed;
    private boolean executing;
    private final List<Fragment> added = new CopyOnWriteArrayList<>();
    private final List<Fragment> active = new CopyOnWriteArrayList<>();
    private final List<BackStackRecord> backStack = new CopyOnWriteArrayList<>();
    private final List<Registered> callbacks = new CopyOnWriteArrayList<>();
    private final List<Runnable> pending = new ArrayList<>();
    private boolean executionPosted;
    private int nextBackStackIndex;

    public FragmentManager() {
        this(null, null, Fragment.INITIALIZING);
    }

    FragmentManager(Context host, Fragment parent, int state) {
        this.host = host;
        this.parent = parent;
        this.state = state;
    }

    public FragmentTransaction beginTransaction() { return new BackStackRecord(this); }

    @Deprecated
    public FragmentTransaction openTransaction() { return beginTransaction(); }

    public boolean executePendingTransactions() {
        checkMainThread();
        if (executing) throw new IllegalStateException("FragmentManager is already executing transactions");
        return execPending();
    }

    public void popBackStack() { enqueue(() -> popBackStackState(null, -1, 0), false); }
    public void popBackStack(String name, int flags) { enqueue(() -> popBackStackState(name, -1, flags), false); }

    public void popBackStack(int id, int flags) {
        if (id < 0) throw new IllegalArgumentException("Bad id: " + id);
        enqueue(() -> popBackStackState(null, id, flags), false);
    }

    public boolean popBackStackImmediate() { return popNow(null, -1, 0); }
    public boolean popBackStackImmediate(String name, int flags) { return popNow(name, -1, flags); }

    public boolean popBackStackImmediate(int id, int flags) {
        if (id < 0) throw new IllegalArgumentException("Bad id: " + id);
        return popNow(null, id, flags);
    }

    public int getBackStackEntryCount() { return backStack.size(); }
    public List<Fragment> getFragments() { return new ArrayList<>(added); }
    public boolean isDestroyed() { return destroyed; }
    public boolean isStateSaved() { return false; }

    public Fragment findFragmentById(int id) {
        for (int i = added.size() - 1; i >= 0; i--) if (added.get(i).containerId == id) return added.get(i);
        for (Fragment fragment : active) if (fragment.containerId == id) return fragment;
        return null;
    }

    public Fragment findFragmentByTag(String tag) {
        if (tag == null) return null;
        for (int i = added.size() - 1; i >= 0; i--) if (tag.equals(added.get(i).tag)) return added.get(i);
        for (Fragment fragment : active) if (tag.equals(fragment.tag)) return fragment;
        return null;
    }

    public void registerFragmentLifecycleCallbacks(FragmentLifecycleCallbacks cb, boolean recursive) {
        callbacks.add(new Registered(cb, recursive));
    }

    public void unregisterFragmentLifecycleCallbacks(FragmentLifecycleCallbacks cb) {
        callbacks.removeIf(registered -> registered.callbacks == cb);
    }

    @Override public String toString() {
        return "FragmentManager{" + Integer.toHexString(System.identityHashCode(this)) + " in " + (parent != null ? parent : host) + "}";
    }

    // Execution, on the main thread.

    void checkMainThread() {
        if (!MainThread.isMainThread()) throw new IllegalStateException("Must be called from main thread of fragment host");
    }

    int allocBackStackIndex() { return nextBackStackIndex++; }

    /** A commit or a pop: it runs after the current main-thread task, after those before it. */
    void enqueue(Runnable action, boolean allowStateLoss) {
        if (destroyed) {
            if (allowStateLoss) return;
            throw new IllegalStateException("FragmentManager has been destroyed");
        }
        synchronized (pending) {
            pending.add(action);
            if (executionPosted) return;
            executionPosted = true;
        }
        MainThread.post(this::execPending);
    }

    private boolean execPending() {
        boolean ran = false;
        try {
            Runnable next;
            while ((next = nextPending()) != null) {
                next.run();
                ran = true;
            }
        } finally {
            // A failing transaction (the extension's crash) leaves the rest for a later turn.
            boolean more;
            synchronized (pending) {
                more = !pending.isEmpty();
                executionPosted = more;
            }
            if (more) MainThread.post(this::execPending);
        }
        return ran;
    }

    private Runnable nextPending() {
        synchronized (pending) {
            return pending.isEmpty() ? null : pending.remove(0);
        }
    }

    void executeNow(BackStackRecord record) {
        checkMainThread();
        if (destroyed) throw new IllegalStateException("FragmentManager has been destroyed");
        execute(record);
    }

    /** Runs [record]'s operations in order, as Android's executeOps does; it joins the back stack if it asked to. */
    void execute(BackStackRecord record) {
        if (executing) throw new IllegalStateException("FragmentManager is already executing transactions");
        executing = true;
        try {
            if (record.addToBackStack) for (FragmentTransaction.Op op : record.ops) op.fragment.backStackNesting++;
            for (FragmentTransaction.Op op : record.ops) {
                Fragment fragment = op.fragment;
                switch (op.cmd) {
                    case FragmentTransaction.OP_ADD:
                        addFragment(fragment);
                        break;
                    case FragmentTransaction.OP_REPLACE:
                        op.replaced.clear();
                        for (Fragment old : added) {
                            if (old == fragment || old.containerId != fragment.containerId) continue;
                            op.replaced.add(old);
                            if (record.addToBackStack) old.backStackNesting++;
                            removeFragment(old);
                        }
                        addFragment(fragment);
                        break;
                    case FragmentTransaction.OP_REMOVE:
                        removeFragment(fragment);
                        break;
                    case FragmentTransaction.OP_HIDE:
                        setHidden(fragment, true);
                        break;
                    case FragmentTransaction.OP_SHOW:
                        setHidden(fragment, false);
                        break;
                    case FragmentTransaction.OP_DETACH:
                        setDetached(fragment, true);
                        break;
                    case FragmentTransaction.OP_ATTACH:
                        setDetached(fragment, false);
                        break;
                    default:
                        break;
                }
            }
            if (record.addToBackStack) backStack.add(record);
        } finally {
            executing = false;
        }
        record.runOnCommitRunnables();
    }

    private boolean popNow(String name, int id, int flags) {
        checkMainThread();
        if (executing) throw new IllegalStateException("FragmentManager is already executing transactions");
        execPending();
        return popBackStackState(name, id, flags);
    }

    /** Pops the entries down to [name] or [id] (that one too with POP_BACK_STACK_INCLUSIVE), or the top one. */
    private boolean popBackStackState(String name, int id, int flags) {
        int index = backStackIndex(name, id, (flags & POP_BACK_STACK_INCLUSIVE) != 0);
        if (index < 0) return false;
        executing = true;
        try {
            for (int i = backStack.size() - 1; i >= index; i--) reverse(backStack.remove(i));
        } finally {
            executing = false;
        }
        return true;
    }

    private int backStackIndex(String name, int id, boolean inclusive) {
        if (backStack.isEmpty()) return -1;
        if (name == null && id < 0) return inclusive ? 0 : backStack.size() - 1;
        int index = backStack.size() - 1;
        while (index >= 0 && !matches(backStack.get(index), name, id)) index--;
        if (index < 0) return -1;
        if (inclusive) {
            while (index > 0 && matches(backStack.get(index - 1), name, id)) index--;
            return index;
        }
        return index == backStack.size() - 1 ? -1 : index + 1;
    }

    private static boolean matches(BackStackRecord record, String name, int id) {
        return (name != null && name.equals(record.name)) || (id >= 0 && id == record.index);
    }

    /** Undoes [record]: its operations reversed, last first; then what no entry keeps any more goes all the way. */
    private void reverse(BackStackRecord record) {
        for (int i = record.ops.size() - 1; i >= 0; i--) {
            FragmentTransaction.Op op = record.ops.get(i);
            Fragment fragment = op.fragment;
            switch (op.cmd) {
                case FragmentTransaction.OP_ADD:
                    removeFragment(fragment);
                    break;
                case FragmentTransaction.OP_REPLACE:
                    removeFragment(fragment);
                    for (Fragment old : op.replaced) addFragment(old);
                    break;
                case FragmentTransaction.OP_REMOVE:
                    addFragment(fragment);
                    break;
                case FragmentTransaction.OP_HIDE:
                    setHidden(fragment, false);
                    break;
                case FragmentTransaction.OP_SHOW:
                    setHidden(fragment, true);
                    break;
                case FragmentTransaction.OP_DETACH:
                    setDetached(fragment, false);
                    break;
                case FragmentTransaction.OP_ATTACH:
                    setDetached(fragment, true);
                    break;
                default:
                    break;
            }
        }
        for (FragmentTransaction.Op op : record.ops) {
            op.fragment.backStackNesting--;
            for (Fragment old : op.replaced) old.backStackNesting--;
        }
        for (FragmentTransaction.Op op : record.ops) {
            moveToExpectedState(op.fragment);
            for (Fragment old : op.replaced) moveToExpectedState(old);
        }
    }

    private void addFragment(Fragment fragment) {
        if (added.contains(fragment)) throw new IllegalStateException("Fragment already added: " + fragment);
        fragment.manager = this;
        if (!active.contains(fragment)) active.add(fragment);
        fragment.removing = false;
        if (!fragment.detached) {
            added.add(fragment);
            fragment.added = true;
        }
        moveToExpectedState(fragment);
    }

    private void removeFragment(Fragment fragment) {
        added.remove(fragment);
        fragment.added = false;
        fragment.removing = true;
        moveToExpectedState(fragment);
    }

    private void setHidden(Fragment fragment, boolean hidden) {
        if (fragment.hidden == hidden) return;
        fragment.hidden = hidden;
        if (fragment.view != null) fragment.view.setVisibility(hidden ? View.GONE : View.VISIBLE);
        fragment.onHiddenChanged(hidden);
    }

    private void setDetached(Fragment fragment, boolean detached) {
        if (fragment.detached == detached) return;
        fragment.detached = detached;
        if (detached) {
            added.remove(fragment);
            fragment.added = false;
        } else if (!added.contains(fragment)) {
            added.add(fragment);
            fragment.added = true;
        }
        moveToExpectedState(fragment);
    }

    /** A fragment's own manager follows it: [newState] is its fragment's. */
    void dispatch(int newState) {
        state = newState;
        for (Fragment fragment : active) moveToExpectedState(fragment);
        if (newState == Fragment.INITIALIZING) destroyed = true;
    }

    private int expectedState(Fragment fragment) {
        int max = state;
        if (fragment.removing) max = Math.min(max, fragment.backStackNesting > 0 ? Fragment.CREATED : Fragment.INITIALIZING);
        if (fragment.detached) max = Math.min(max, Fragment.CREATED);
        return max;
    }

    private void moveToExpectedState(Fragment fragment) {
        moveTo(fragment, expectedState(fragment));
        if (fragment.state == Fragment.INITIALIZING && (fragment.removing || destroyed || state == Fragment.INITIALIZING)) {
            active.remove(fragment);
            added.remove(fragment);
            fragment.reset();
        }
    }

    private void moveTo(Fragment f, int target) {
        while (f.state < target) {
            switch (f.state) {
                case Fragment.INITIALIZING:
                    tell(f, false, (cb, fm) -> cb.onFragmentPreAttached(fm, f, host));
                    f.performAttach(host, parent);
                    tell(f, false, (cb, fm) -> cb.onFragmentAttached(fm, f, host));
                    break;
                case Fragment.ATTACHED:
                    tell(f, false, (cb, fm) -> cb.onFragmentPreCreated(fm, f, null));
                    f.performCreate();
                    tell(f, false, (cb, fm) -> cb.onFragmentCreated(fm, f, null));
                    break;
                case Fragment.CREATED:
                    if (f.performCreateView(containerFor(f))) tell(f, false, (cb, fm) -> cb.onFragmentViewCreated(fm, f, f.view, null));
                    tell(f, false, (cb, fm) -> cb.onFragmentActivityCreated(fm, f, null));
                    break;
                case Fragment.VIEW_CREATED:
                    f.performStart();
                    tell(f, false, (cb, fm) -> cb.onFragmentStarted(fm, f));
                    break;
                case Fragment.STARTED:
                    f.performResume();
                    tell(f, false, (cb, fm) -> cb.onFragmentResumed(fm, f));
                    break;
                default:
                    return;
            }
        }
        while (f.state > target) {
            switch (f.state) {
                case Fragment.RESUMED:
                    f.performPause();
                    tell(f, false, (cb, fm) -> cb.onFragmentPaused(fm, f));
                    break;
                case Fragment.STARTED:
                    f.performStop();
                    tell(f, false, (cb, fm) -> cb.onFragmentStopped(fm, f));
                    break;
                case Fragment.VIEW_CREATED:
                    f.performDestroyView();
                    tell(f, false, (cb, fm) -> cb.onFragmentViewDestroyed(fm, f));
                    break;
                case Fragment.CREATED:
                    f.performDestroy();
                    tell(f, false, (cb, fm) -> cb.onFragmentDestroyed(fm, f));
                    break;
                case Fragment.ATTACHED:
                    f.performDetach();
                    tell(f, false, (cb, fm) -> cb.onFragmentDetached(fm, f));
                    break;
                default:
                    return;
            }
        }
    }

    /** The container [fragment]'s view goes in: none for id 0, else found as Android finds it, or Android's error. */
    private ViewGroup containerFor(Fragment fragment) {
        if (fragment.containerId == 0) return null;
        View found = parent != null ? parent.findContainerView(fragment.containerId)
            : host instanceof Activity ? ((Activity) host).findViewById(fragment.containerId) : null;
        if (!(found instanceof ViewGroup)) {
            throw new IllegalArgumentException("No view found for id 0x" + Integer.toHexString(fragment.containerId) + " (unknown) for fragment " + fragment);
        }
        return (ViewGroup) found;
    }

    /** Tells the lifecycle callbacks about [fragment]'s step: the recursive ones of the managers above first, as Android's. */
    private void tell(Fragment fragment, boolean onlyRecursive, Step step) {
        if (parent != null && parent.manager != null) parent.manager.tell(fragment, true, step);
        for (Registered registered : callbacks) if (!onlyRecursive || registered.recursive) step.tell(registered.callbacks, this);
    }
}
