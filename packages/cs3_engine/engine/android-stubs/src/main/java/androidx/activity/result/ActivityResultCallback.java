package androidx.activity.result;

/** Hears an activity's result. */
public interface ActivityResultCallback<O> {
    void onActivityResult(O result);
}
