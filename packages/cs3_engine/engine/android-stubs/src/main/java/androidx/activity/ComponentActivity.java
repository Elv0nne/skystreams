package androidx.activity;

import androidx.activity.result.ActivityResultCallback;
import androidx.activity.result.ActivityResultCaller;
import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContract;
import dev.akash.cs3engine.stubs.NoResultLauncher;

/** The activity Back is dispatched through, and results registered with. */
public class ComponentActivity extends androidx.core.app.ComponentActivity implements OnBackPressedDispatcherOwner, ActivityResultCaller {
    private final OnBackPressedDispatcher dispatcher = new OnBackPressedDispatcher(() -> ComponentActivity.super.onBackPressed());

    public ComponentActivity() {}

    @Override public final OnBackPressedDispatcher getOnBackPressedDispatcher() { return dispatcher; }

    @Override public void onBackPressed() { dispatcher.onBackPressed(); }

    /** No other app runs beside the engine: each launch is answered as cancelled (NoResultLauncher). */
    @Override public final <I, O> ActivityResultLauncher<I> registerForActivityResult(ActivityResultContract<I, O> contract, ActivityResultCallback<O> callback) {
        return new NoResultLauncher<>(contract, callback);
    }
}
