package android.webkit;

/**
 * A page dialog's answer, which the extension's chrome client gives (Phase 7c's §8): confirm or cancel, once, from any
 * thread, now or later. SkyStream's stand-in hears it through its receiver, as Android's WebView does through its own.
 */
public class JsResult {
    /** Hears the answer: SkyStream's own, as Android's (hidden) one is its WebView's. */
    public interface ResultReceiver {
        void onJsResultComplete(JsResult result);
    }

    private final ResultReceiver receiver;
    private boolean result;
    private boolean done;

    public JsResult(ResultReceiver receiver) {
        this.receiver = receiver;
    }

    public final void cancel() {
        complete(false);
    }

    public final void confirm() {
        complete(true);
    }

    /** Whether the dialog was confirmed. */
    public final boolean getResult() {
        return result;
    }

    private void complete(boolean confirmed) {
        synchronized (this) {
            if (done) return;
            done = true;
            result = confirmed;
        }
        if (receiver != null) receiver.onJsResultComplete(this);
    }
}
