package androidx.activity.result.contract;

import android.content.Context;
import android.content.Intent;

/** An activity's input and output: the intent that starts it, and its result read back. */
public abstract class ActivityResultContract<I, O> {
    public ActivityResultContract() {}

    public abstract Intent createIntent(Context context, I input);

    public abstract O parseResult(int resultCode, Intent intent);
}
