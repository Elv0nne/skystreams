package androidx.fragment.app;

/** The manager an activity or a fragment has; FragmentManager holds the workings, as Android's does. */
class FragmentManagerImpl extends FragmentManager {
    /** The activity's: resumed, as the engine's activity always is. */
    FragmentManagerImpl(FragmentActivity activity) {
        super(activity, null, Fragment.RESUMED);
    }

    /** A fragment's own: it follows the fragment from attach on. */
    FragmentManagerImpl(Fragment parent) {
        super(parent.host, parent, Fragment.INITIALIZING);
    }
}
