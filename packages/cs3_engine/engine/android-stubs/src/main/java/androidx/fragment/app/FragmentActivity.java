package androidx.fragment.app;

import androidx.activity.ComponentActivity;

/** An activity with fragments: one manager, resumed with it. */
public class FragmentActivity extends ComponentActivity {
    private FragmentManager fragments;

    public FragmentActivity() {}

    public synchronized FragmentManager getSupportFragmentManager() {
        if (fragments == null) fragments = new FragmentManagerImpl(this);
        return fragments;
    }
}
