package dev.akash.cs3engine.stubs

import android.app.Activity
import android.content.Context
import android.content.Intent
import androidx.activity.OnBackPressedCallback
import androidx.activity.OnBackPressedDispatcher
import androidx.activity.result.contract.ActivityResultContract
import androidx.fragment.app.Fragment
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse

/** Something with a lifecycle its test moves. */
class Owner : LifecycleOwner {
    val registry = LifecycleRegistry(this)

    override fun getLifecycle(): Lifecycle = registry
}

class LifecycleTest {
    @Test
    fun `observers hear each step, a late one catches up, and going down the newest hears first`() {
        val owner = Owner()
        val heard = mutableListOf<String>()
        owner.registry.addObserver(LifecycleEventObserver { _, event -> heard += "first $event" })
        owner.registry.currentState = Lifecycle.State.RESUMED
        owner.registry.addObserver(
            object : DefaultLifecycleObserver {
                override fun onCreate(owner: LifecycleOwner) {
                    heard += "late ON_CREATE"
                }

                override fun onResume(owner: LifecycleOwner) {
                    heard += "late ON_RESUME"
                }

                override fun onPause(owner: LifecycleOwner) {
                    heard += "late ON_PAUSE"
                }

                override fun onDestroy(owner: LifecycleOwner) {
                    heard += "late ON_DESTROY"
                }
            },
        )
        owner.registry.handleLifecycleEvent(Lifecycle.Event.ON_DESTROY)
        assertEquals(
            listOf(
                "first ON_CREATE", "first ON_START", "first ON_RESUME",
                "late ON_CREATE", "late ON_RESUME",
                "late ON_PAUSE", "late ON_DESTROY",
                "first ON_PAUSE", "first ON_STOP", "first ON_DESTROY",
            ),
            heard,
        )
        assertEquals(0, owner.registry.observerCount, "a destroyed lifecycle lets its observers go")
    }

    @Test
    fun `a lifecycle can't be destroyed before it's created, as Android's can't`() {
        assertFailsWith<IllegalStateException> { Owner().registry.currentState = Lifecycle.State.DESTROYED }
    }

    @Test
    fun `Back goes to the newest enabled callback, a lifecycle's only while it's started, else the fallback`() {
        var fallbacks = 0
        val dispatcher = OnBackPressedDispatcher { fallbacks++ }
        val heard = mutableListOf<String>()
        val first = object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                heard += "first"
            }
        }
        val second = object : OnBackPressedCallback(false) {
            override fun handleOnBackPressed() {
                heard += "second"
            }
        }
        dispatcher.addCallback(first)
        dispatcher.addCallback(second)
        dispatcher.onBackPressed()
        second.isEnabled = true
        dispatcher.onBackPressed()
        second.remove()
        first.remove()
        dispatcher.onBackPressed()
        assertEquals(listOf("first", "second"), heard)
        assertEquals(1, fallbacks)

        val owner = Owner()
        val bound = object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                heard += "bound"
            }
        }
        dispatcher.addCallback(owner, bound)
        assertFalse(dispatcher.hasEnabledCallbacks(), "not before its owner starts")
        owner.registry.currentState = Lifecycle.State.STARTED
        dispatcher.onBackPressed()
        owner.registry.currentState = Lifecycle.State.DESTROYED
        dispatcher.onBackPressed()
        assertEquals(listOf("first", "second", "bound"), heard)
        assertEquals(2, fallbacks)
    }

    @Test
    fun `an activity result no app here can give is answered as cancelled, after the current task`() {
        class Pick : ActivityResultContract<String, String>() {
            override fun createIntent(context: Context, input: String) = Intent("android.intent.action.OPEN_DOCUMENT")

            override fun parseResult(resultCode: Int, intent: Intent?) = if (resultCode == Activity.RESULT_OK) "picked" else "cancelled $intent"
        }
        val answers = mutableListOf<String>()
        val launcher = Fragment().registerForActivityResult(Pick()) { answers += it }
        onMain {
            launcher.launch("text/plain")
            assertEquals(emptyList(), answers, "as Android's, the answer comes later")
        }
        drainMain()
        assertEquals(listOf("cancelled null"), answers)
        launcher.unregister()
        assertFailsWith<IllegalStateException> { launcher.launch("text/plain") }
    }
}
