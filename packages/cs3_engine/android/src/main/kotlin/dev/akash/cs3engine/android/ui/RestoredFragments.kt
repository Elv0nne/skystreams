package dev.akash.cs3engine.android.ui

import android.os.Bundle
import android.util.Log
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentFactory

/**
 * An extension's fragments can't come back when Android restores the activity (Don't keep activities, a
 * configuration change it doesn't handle, the process dying in the background): their classes are the
 * plugin's, which the app's class loader can't see. Each comes back as [Gone], which goes at once with any
 * fragments it held, instead of failing the activity's start. The app's own fragments come back as they were.
 */
class RestoredFragments(private val base: FragmentFactory) : FragmentFactory() {
    override fun instantiate(classLoader: ClassLoader, className: String): Fragment {
        if (runCatching { loadFragmentClass(classLoader, className) }.isSuccess) return base.instantiate(classLoader, className)
        Log.i("cs3", "an extension's fragment doesn't come back with the activity: $className")
        return Gone()
    }

    /** Stands for an extension's fragment that couldn't come back: it removes itself. */
    class Gone : Fragment() {
        override fun onCreate(savedInstanceState: Bundle?) {
            super.onCreate(savedInstanceState)
            parentFragmentManager.beginTransaction().remove(this).commitAllowingStateLoss()
        }
    }
}
