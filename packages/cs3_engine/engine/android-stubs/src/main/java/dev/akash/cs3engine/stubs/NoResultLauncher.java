package dev.akash.cs3engine.stubs;

import android.app.Activity;
import androidx.activity.result.ActivityResultCallback;
import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContract;
import androidx.core.app.ActivityOptionsCompat;

/**
 * An activity result the engine can't give: no other app runs beside it (a file picker, for one). Each launch
 * is answered as Android answers a cancelled one, the contract reading RESULT_CANCELED with no data, after
 * the current main-thread task.
 */
public final class NoResultLauncher<I, O> extends ActivityResultLauncher<I> {
    private final ActivityResultContract<I, O> contract;
    private final ActivityResultCallback<O> callback;
    private volatile boolean registered = true;

    public NoResultLauncher(ActivityResultContract<I, O> contract, ActivityResultCallback<O> callback) {
        this.contract = contract;
        this.callback = callback;
    }

    @Override public void launch(I input, ActivityOptionsCompat options) {
        if (!registered) {
            throw new IllegalStateException("Attempting to launch an unregistered ActivityResultLauncher with contract " + contract
                + " and input " + input + ". You must ensure the ActivityResultLauncher is registered before calling launch().");
        }
        System.err.println("[cs3] " + contract.getClass().getName() + " needs another app, which can't run here: answered as cancelled");
        MainThread.post(() -> callback.onActivityResult(contract.parseResult(Activity.RESULT_CANCELED, null)));
    }

    @Override public void unregister() { registered = false; }

    @Override public ActivityResultContract<I, ?> getContract() { return contract; }
}
