package androidx.fragment.app;

import android.view.View;
import java.util.ArrayList;

/** Fragment operations, run in order when committed. */
public abstract class FragmentTransaction {
    static final int OP_ADD = 1;
    static final int OP_REPLACE = 2;
    static final int OP_REMOVE = 3;
    static final int OP_HIDE = 4;
    static final int OP_SHOW = 5;
    static final int OP_DETACH = 6;
    static final int OP_ATTACH = 7;

    /** One operation. A replace remembers what it removed: popping it puts those back. */
    static final class Op {
        final int cmd;
        final Fragment fragment;
        final ArrayList<Fragment> replaced = new ArrayList<>();

        Op(int cmd, Fragment fragment) {
            this.cmd = cmd;
            this.fragment = fragment;
        }
    }

    final ArrayList<Op> ops = new ArrayList<>();
    boolean addToBackStack;
    String name;
    private boolean allowAddToBackStack = true;
    private final ArrayList<Runnable> commitRunnables = new ArrayList<>();

    public FragmentTransaction() {}

    public FragmentTransaction add(Fragment fragment, String tag) {
        doAddOp(0, fragment, tag, OP_ADD);
        return this;
    }

    public FragmentTransaction add(int containerViewId, Fragment fragment) {
        doAddOp(containerViewId, fragment, null, OP_ADD);
        return this;
    }

    public FragmentTransaction add(int containerViewId, Fragment fragment, String tag) {
        doAddOp(containerViewId, fragment, tag, OP_ADD);
        return this;
    }

    public FragmentTransaction replace(int containerViewId, Fragment fragment) {
        return replace(containerViewId, fragment, null);
    }

    public FragmentTransaction replace(int containerViewId, Fragment fragment, String tag) {
        if (containerViewId == 0) throw new IllegalArgumentException("Must use non-zero containerViewId");
        doAddOp(containerViewId, fragment, tag, OP_REPLACE);
        return this;
    }

    public FragmentTransaction remove(Fragment fragment) { return op(OP_REMOVE, fragment); }
    public FragmentTransaction hide(Fragment fragment) { return op(OP_HIDE, fragment); }
    public FragmentTransaction show(Fragment fragment) { return op(OP_SHOW, fragment); }
    public FragmentTransaction detach(Fragment fragment) { return op(OP_DETACH, fragment); }
    public FragmentTransaction attach(Fragment fragment) { return op(OP_ATTACH, fragment); }
    public boolean isEmpty() { return ops.isEmpty(); }
    public FragmentTransaction setCustomAnimations(int enter, int exit) { return this; }
    public FragmentTransaction setCustomAnimations(int enter, int exit, int popEnter, int popExit) { return this; }
    public FragmentTransaction setTransition(int transition) { return this; }
    public FragmentTransaction setReorderingAllowed(boolean reorderingAllowed) { return this; }

    public FragmentTransaction addToBackStack(String name) {
        if (!allowAddToBackStack) throw new IllegalStateException("This FragmentTransaction is not allowed to be added to the back stack.");
        addToBackStack = true;
        this.name = name;
        return this;
    }

    public FragmentTransaction disallowAddToBackStack() {
        if (addToBackStack) throw new IllegalStateException("This transaction is already being added to the back stack");
        allowAddToBackStack = false;
        return this;
    }

    public FragmentTransaction runOnCommit(Runnable runnable) {
        disallowAddToBackStack();
        commitRunnables.add(runnable);
        return this;
    }

    public abstract int commit();

    public abstract int commitAllowingStateLoss();

    public abstract void commitNow();

    public abstract void commitNowAllowingStateLoss();

    private FragmentTransaction op(int cmd, Fragment fragment) {
        ops.add(new Op(cmd, fragment));
        return this;
    }

    void doAddOp(int containerViewId, Fragment fragment, String tag, int cmd) {
        if (tag != null) {
            if (fragment.tag != null && !tag.equals(fragment.tag)) {
                throw new IllegalStateException("Can't change tag of fragment " + fragment + ": was " + fragment.tag + " now " + tag);
            }
            fragment.tag = tag;
        }
        if (containerViewId != 0) {
            if (containerViewId == View.NO_ID) {
                throw new IllegalArgumentException("Can't add fragment " + fragment + " with tag " + tag + " to container view with no id");
            }
            if (fragment.containerId != 0 && fragment.containerId != containerViewId) {
                throw new IllegalStateException("Can't change container ID of fragment " + fragment + ": was " + fragment.containerId + " now " + containerViewId);
            }
            fragment.containerId = containerViewId;
        }
        ops.add(new Op(cmd, fragment));
    }

    void runOnCommitRunnables() {
        for (Runnable runnable : commitRunnables) runnable.run();
        commitRunnables.clear();
    }
}
