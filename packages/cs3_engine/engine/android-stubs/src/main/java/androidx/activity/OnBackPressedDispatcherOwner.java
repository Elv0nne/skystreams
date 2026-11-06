package androidx.activity;

import androidx.lifecycle.LifecycleOwner;

/** Something Back is dispatched through: an activity, a dialog. */
public interface OnBackPressedDispatcherOwner extends LifecycleOwner {
    OnBackPressedDispatcher getOnBackPressedDispatcher();
}
