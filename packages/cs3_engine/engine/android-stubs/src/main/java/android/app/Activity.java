package android.app;

import android.content.ContextWrapper;
import android.content.Intent;
import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.Window;
import dev.akash.cs3engine.stubs.MainThread;

/** The engine's activity: never finishes, runs UI work on the engine's main thread, starts through the platform. */
public class Activity extends ContextWrapper {
    public static final int RESULT_CANCELED = 0;
    public static final int RESULT_OK = -1;

    private Intent intent = new Intent(Intent.ACTION_MAIN);

    public Activity() {
        super(null);
    }

    public void runOnUiThread(Runnable action) {
        if (MainThread.isMainThread()) action.run();
        else MainThread.post(action);
    }

    public boolean isFinishing() { return false; }
    public boolean isDestroyed() { return false; }
    public void finish() {}
    public Intent getIntent() { return intent; }
    public void setIntent(Intent newIntent) { intent = newIntent; }
    public void startActivityForResult(Intent intent, int requestCode) { startActivity(intent); }
    public void startActivityForResult(Intent intent, int requestCode, Bundle options) { startActivity(intent); }
    public LayoutInflater getLayoutInflater() { return LayoutInflater.from(this); }

    private Window window;

    public Window getWindow() {
        if (window == null) window = new Window(this);
        return window;
    }

    /** SCREEN_ORIENTATION_UNSPECIFIED until the extension asks for one. */
    private int requestedOrientation = -1;

    /** What the extension asks of the activity: a full-screen window carries it to the app, where an iPhone turns (Phase 7c's §5). */
    public void setRequestedOrientation(int requestedOrientation) {
        this.requestedOrientation = requestedOrientation;
        dev.akash.cs3engine.stubs.Ui.changed();
    }

    public int getRequestedOrientation() { return requestedOrientation; }

    /** Back with nothing to handle it: an activity finishes, which the engine's never does. */
    public void onBackPressed() { finish(); }

    public <T extends View> T findViewById(int id) { return getWindow().findViewById(id); }
}
