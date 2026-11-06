package androidx.fragment.app;

/** A transaction, committed to its manager; it stays as a back-stack entry when it asked to. */
final class BackStackRecord extends FragmentTransaction {
    private final FragmentManager manager;
    private boolean committed;
    int index = -1;

    BackStackRecord(FragmentManager manager) {
        this.manager = manager;
    }

    @Override void doAddOp(int containerViewId, Fragment fragment, String tag, int cmd) {
        if (fragment.manager != null && fragment.manager != manager) {
            throw new IllegalStateException("Cannot add Fragment attached to a different FragmentManager. Fragment " + fragment
                + " is already attached to a FragmentManager.");
        }
        super.doAddOp(containerViewId, fragment, tag, cmd);
        fragment.manager = manager;
    }

    @Override public int commit() { return commitInternal(false); }
    @Override public int commitAllowingStateLoss() { return commitInternal(true); }

    @Override public void commitNow() {
        disallowAddToBackStack();
        manager.executeNow(this);
    }

    @Override public void commitNowAllowingStateLoss() { commitNow(); }

    private int commitInternal(boolean allowStateLoss) {
        if (committed) throw new IllegalStateException("commit already called");
        committed = true;
        index = addToBackStack ? manager.allocBackStackIndex() : -1;
        manager.enqueue(() -> manager.execute(this), allowStateLoss);
        return index;
    }
}
