package android.webkit;

/** A prompt's answer (Phase 7c's §8): its text, when confirmed with one. */
public class JsPromptResult extends JsResult {
    private String stringResult;

    public JsPromptResult(ResultReceiver receiver) {
        super(receiver);
    }

    public void confirm(String result) {
        stringResult = result;
        confirm();
    }

    /** The prompt's text: null when cancelled, or confirmed with none. */
    public String getStringResult() {
        return stringResult;
    }
}
