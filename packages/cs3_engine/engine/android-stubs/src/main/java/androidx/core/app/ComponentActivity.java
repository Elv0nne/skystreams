package androidx.core.app;

import android.app.Activity;
import androidx.lifecycle.Lifecycle;
import androidx.lifecycle.LifecycleOwner;
import androidx.lifecycle.LifecycleRegistry;

/**
 * AppCompatActivity's ancestry, so plugins' `context as AppCompatActivity` casts succeed. Its lifecycle is
 * resumed: the engine's activity is the app, in front.
 */
public class ComponentActivity extends Activity implements LifecycleOwner {
    private final LifecycleRegistry lifecycle = new LifecycleRegistry(this);

    public ComponentActivity() {
        lifecycle.setCurrentState(Lifecycle.State.RESUMED);
    }

    @Override public Lifecycle getLifecycle() { return lifecycle; }
}
