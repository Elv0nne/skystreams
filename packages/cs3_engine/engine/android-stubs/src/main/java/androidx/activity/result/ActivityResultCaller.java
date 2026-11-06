package androidx.activity.result;

import androidx.activity.result.contract.ActivityResultContract;

/** What can start an activity for its result: fragments and activities. framework-gen adds the registry form. */
public interface ActivityResultCaller {
    <I, O> ActivityResultLauncher<I> registerForActivityResult(ActivityResultContract<I, O> contract, ActivityResultCallback<O> callback);
}
