package androidx.fragment.app;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.res.Configuration;
import android.content.res.Resources;
import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import androidx.activity.result.ActivityResultCallback;
import androidx.activity.result.ActivityResultCaller;
import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContract;
import androidx.lifecycle.Lifecycle;
import androidx.lifecycle.LifecycleOwner;
import androidx.lifecycle.LifecycleRegistry;
import dev.akash.cs3engine.stubs.NoResultLauncher;

/**
 * A stand-in fragment. Its manager moves it through Android's lifecycle in Android's order, calling the
 * extension's overrides; its lifecycle and its view's follow. Nothing is saved or restored.
 */
public class Fragment implements LifecycleOwner, ActivityResultCaller {
    static final int INITIALIZING = -1;
    static final int ATTACHED = 0;
    static final int CREATED = 1;
    static final int VIEW_CREATED = 2;
    static final int STARTED = 5;
    static final int RESUMED = 7;

    private final int contentLayoutId;
    private LifecycleRegistry lifecycle = new LifecycleRegistry(this);
    private Bundle arguments;
    private LayoutInflater layoutInflater;
    int state = INITIALIZING;
    FragmentManager manager;
    FragmentManager children;
    Context host;
    Fragment parent;
    String tag;
    int containerId;
    ViewGroup container;
    View view;
    FragmentViewLifecycleOwner viewLifecycleOwner;
    boolean added;
    boolean removing;
    boolean detached;
    boolean hidden;
    int backStackNesting;

    public Fragment() {
        this(0);
    }

    public Fragment(int contentLayoutId) {
        this.contentLayoutId = contentLayoutId;
    }

    @Override public Lifecycle getLifecycle() { return lifecycle; }

    public LifecycleOwner getViewLifecycleOwner() {
        if (viewLifecycleOwner == null) {
            throw new IllegalStateException("Can't access the Fragment View's LifecycleOwner for " + this
                + " when getView() is null i.e., before onCreateView() or after onDestroyView()");
        }
        return viewLifecycleOwner;
    }

    public final int getId() { return containerId; }
    public final String getTag() { return tag; }
    public void setArguments(Bundle args) { arguments = args; }
    public final Bundle getArguments() { return arguments; }

    public final Bundle requireArguments() {
        if (arguments == null) throw new IllegalStateException("Fragment " + this + " does not have any arguments.");
        return arguments;
    }

    public final boolean isStateSaved() { return false; }
    public Context getContext() { return host; }

    public final Context requireContext() {
        Context context = getContext();
        if (context == null) throw new IllegalStateException("Fragment " + this + " not attached to a context.");
        return context;
    }

    public final FragmentActivity getActivity() { return host instanceof FragmentActivity ? (FragmentActivity) host : null; }

    public final FragmentActivity requireActivity() {
        FragmentActivity activity = getActivity();
        if (activity == null) throw new IllegalStateException("Fragment " + this + " not attached to an activity.");
        return activity;
    }

    public final Object getHost() { return host; }
    public final Resources getResources() { return requireContext().getResources(); }
    public final CharSequence getText(int resId) { return requireContext().getText(resId); }
    public final String getString(int resId) { return requireContext().getString(resId); }
    public final String getString(int resId, Object... formatArgs) { return String.format(getString(resId), formatArgs); }

    @Deprecated
    public final FragmentManager getFragmentManager() { return manager; }

    public final FragmentManager getParentFragmentManager() {
        if (manager == null) throw new IllegalStateException("Fragment " + this + " not associated with a fragment manager.");
        return manager;
    }

    @Deprecated
    public final FragmentManager requireFragmentManager() { return getParentFragmentManager(); }

    public final FragmentManager getChildFragmentManager() {
        if (children == null) throw new IllegalStateException("Fragment " + this + " has not been attached yet.");
        return children;
    }

    public final Fragment getParentFragment() { return parent; }

    public final Fragment requireParentFragment() {
        if (parent != null) return parent;
        if (getContext() == null) throw new IllegalStateException("Fragment " + this + " is not attached to any Fragment or host");
        throw new IllegalStateException("Fragment " + this + " is not a child Fragment, it is directly attached to " + getContext());
    }

    public final boolean isAdded() { return host != null && added; }
    public final boolean isDetached() { return detached; }
    public final boolean isRemoving() { return removing; }
    public final boolean isInLayout() { return false; }
    public final boolean isResumed() { return state >= RESUMED; }
    public final boolean isHidden() { return hidden || (parent != null && parent.isHidden()); }
    public final boolean isVisible() { return isAdded() && !isHidden() && view != null && view.getVisibility() == View.VISIBLE; }

    public void startActivity(Intent intent) {
        startActivity(intent, null);
    }

    public void startActivity(Intent intent, Bundle options) {
        if (host == null) throw new IllegalStateException("Fragment " + this + " not attached to Activity");
        host.startActivity(intent);
    }

    @Deprecated
    public void startActivityForResult(Intent intent, int requestCode) {
        startActivity(intent);
    }

    /** No other app runs beside the engine: each launch is answered as cancelled (NoResultLauncher). */
    @Override public final <I, O> ActivityResultLauncher<I> registerForActivityResult(ActivityResultContract<I, O> contract, ActivityResultCallback<O> callback) {
        return new NoResultLauncher<>(contract, callback);
    }

    public LayoutInflater onGetLayoutInflater(Bundle savedInstanceState) {
        if (host == null) throw new IllegalStateException("onGetLayoutInflater() cannot be executed until the Fragment is attached to the FragmentManager.");
        return LayoutInflater.from(host);
    }

    public final LayoutInflater getLayoutInflater() {
        return layoutInflater != null ? layoutInflater : performGetLayoutInflater(null);
    }

    LayoutInflater performGetLayoutInflater(Bundle savedInstanceState) {
        layoutInflater = onGetLayoutInflater(savedInstanceState);
        return layoutInflater;
    }

    public void onAttach(Context context) {
        if (context instanceof Activity) onAttach((Activity) context);
    }

    @Deprecated
    public void onAttach(Activity activity) {}

    public void onCreate(Bundle savedInstanceState) {}

    public View onCreateView(LayoutInflater inflater, ViewGroup container, Bundle savedInstanceState) {
        return contentLayoutId != 0 ? inflater.inflate(contentLayoutId, container, false) : null;
    }

    public void onViewCreated(View view, Bundle savedInstanceState) {}
    public View getView() { return view; }

    public final View requireView() {
        if (view == null) {
            throw new IllegalStateException("Fragment " + this + " did not return a View from onCreateView() or this was called before onCreateView().");
        }
        return view;
    }

    @Deprecated
    public void onActivityCreated(Bundle savedInstanceState) {}

    public void onViewStateRestored(Bundle savedInstanceState) {}
    public void onStart() {}
    public void onResume() {}
    public void onSaveInstanceState(Bundle outState) {}
    public void onConfigurationChanged(Configuration newConfig) {}
    public void onHiddenChanged(boolean hidden) {}
    public void onPause() {}
    public void onStop() {}
    public void onLowMemory() {}
    public void onDestroyView() {}
    public void onDestroy() {}
    public void onDetach() {}

    @Override public final boolean equals(Object o) { return super.equals(o); }
    @Override public final int hashCode() { return super.hashCode(); }

    @Override public String toString() {
        StringBuilder out = new StringBuilder(getClass().getSimpleName()).append('{').append(Integer.toHexString(System.identityHashCode(this))).append('}');
        if (containerId != 0) out.append(" id=0x").append(Integer.toHexString(containerId));
        if (tag != null) out.append(" tag=").append(tag);
        return out.toString();
    }

    // The steps its manager takes, in Android's order (FragmentStateManager's).

    /** Its view is made, before onViewCreated: a DialogFragment puts it in its dialog. */
    void onViewAvailable(View view) {}

    /** Where a child's container is found: this fragment's view (a DialogFragment's dialog without one). */
    View findContainerView(int id) {
        if (view == null) throw new IllegalStateException("Fragment " + this + " does not have a view");
        return view.findViewById(id);
    }

    void performAttach(Context host, Fragment parent) {
        if (lifecycle.getCurrentState() == Lifecycle.State.DESTROYED) lifecycle = new LifecycleRegistry(this);
        this.host = host;
        this.parent = parent;
        children = new FragmentManagerImpl(this);
        state = ATTACHED;
        onAttach(host);
        children.dispatch(ATTACHED);
    }

    void performCreate() {
        state = CREATED;
        onCreate(null);
        lifecycle.handleLifecycleEvent(Lifecycle.Event.ON_CREATE);
        children.dispatch(CREATED);
    }

    /** Makes the view in [container] (null for a dialog's or a headless fragment's); true when it made one. */
    boolean performCreateView(ViewGroup container) {
        this.container = container;
        viewLifecycleOwner = new FragmentViewLifecycleOwner();
        view = onCreateView(performGetLayoutInflater(null), container, null);
        state = VIEW_CREATED;
        if (view == null) {
            viewLifecycleOwner = null;
        } else {
            onViewAvailable(view);
            if (container != null) container.addView(view);
            if (hidden) view.setVisibility(View.GONE);
            onViewCreated(view, null);
        }
        onActivityCreated(null);
        onViewStateRestored(null);
        if (view != null) viewLifecycleOwner.registry.handleLifecycleEvent(Lifecycle.Event.ON_CREATE);
        children.dispatch(VIEW_CREATED);
        return view != null;
    }

    void performStart() {
        state = STARTED;
        onStart();
        lifecycle.handleLifecycleEvent(Lifecycle.Event.ON_START);
        if (viewLifecycleOwner != null) viewLifecycleOwner.registry.handleLifecycleEvent(Lifecycle.Event.ON_START);
        children.dispatch(STARTED);
    }

    void performResume() {
        state = RESUMED;
        onResume();
        lifecycle.handleLifecycleEvent(Lifecycle.Event.ON_RESUME);
        if (viewLifecycleOwner != null) viewLifecycleOwner.registry.handleLifecycleEvent(Lifecycle.Event.ON_RESUME);
        children.dispatch(RESUMED);
    }

    void performPause() {
        children.dispatch(STARTED);
        if (viewLifecycleOwner != null) viewLifecycleOwner.registry.handleLifecycleEvent(Lifecycle.Event.ON_PAUSE);
        lifecycle.handleLifecycleEvent(Lifecycle.Event.ON_PAUSE);
        state = STARTED;
        onPause();
    }

    void performStop() {
        children.dispatch(VIEW_CREATED);
        if (viewLifecycleOwner != null) viewLifecycleOwner.registry.handleLifecycleEvent(Lifecycle.Event.ON_STOP);
        lifecycle.handleLifecycleEvent(Lifecycle.Event.ON_STOP);
        state = VIEW_CREATED;
        onStop();
    }

    void performDestroyView() {
        children.dispatch(CREATED);
        if (viewLifecycleOwner != null) viewLifecycleOwner.registry.handleLifecycleEvent(Lifecycle.Event.ON_DESTROY);
        state = CREATED;
        onDestroyView();
        if (view != null && container != null && view.getParent() == container) container.removeView(view);
        view = null;
        container = null;
        viewLifecycleOwner = null;
    }

    void performDestroy() {
        children.dispatch(INITIALIZING);
        lifecycle.handleLifecycleEvent(Lifecycle.Event.ON_DESTROY);
        state = ATTACHED;
        onDestroy();
    }

    void performDetach() {
        state = INITIALIZING;
        onDetach();
        host = null;
        parent = null;
        manager = null;
        children = null;
        layoutInflater = null;
    }

    /** Android's initState: fully removed (not kept by a back stack), it can be added again, as new. */
    void reset() {
        tag = null;
        containerId = 0;
        added = false;
        removing = false;
        detached = false;
        hidden = false;
        backStackNesting = 0;
    }
}
