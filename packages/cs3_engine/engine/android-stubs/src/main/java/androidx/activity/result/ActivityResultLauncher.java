package androidx.activity.result;

import androidx.activity.result.contract.ActivityResultContract;
import androidx.core.app.ActivityOptionsCompat;

/** Starts its contract's activity with an input; the callback registered with it hears the result. */
public abstract class ActivityResultLauncher<I> {
    public ActivityResultLauncher() {}

    public void launch(I input) {
        launch(input, null);
    }

    public abstract void launch(I input, ActivityOptionsCompat options);

    public abstract void unregister();

    public abstract ActivityResultContract<I, ?> getContract();
}
