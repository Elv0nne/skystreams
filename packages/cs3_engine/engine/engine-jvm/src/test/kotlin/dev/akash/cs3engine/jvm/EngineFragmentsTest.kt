package dev.akash.cs3engine.jvm

import android.os.Bundle
import androidx.activity.result.contract.ActivityResultContract
import androidx.fragment.app.Fragment
import androidx.lifecycle.coroutineScope
import androidx.lifecycle.lifecycleScope
import com.lagradost.cloudstream3.MainActivity
import dev.akash.cs3engine.stubs.MainThread
import kotlinx.coroutines.Job
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertSame
import kotlin.test.assertTrue

class EngineFragmentsTest {
    class Watching : Fragment() {
        @Volatile
        var ranOnMain = false
        lateinit var job: Job

        override fun onCreate(savedInstanceState: Bundle?) {
            super.onCreate(savedInstanceState)
            job = lifecycleScope.launch {
                ranOnMain = MainThread.isMainThread()
                awaitCancellation()
            }
        }
    }

    @Test
    fun `a fragment's lifecycleScope runs on the main thread and ends with the fragment`() {
        val activity = MainActivity()
        val fragment = Watching()
        onMain { activity.supportFragmentManager.beginTransaction().add(fragment, "watching").commitNow() }
        assertTrue(fragment.ranOnMain, "Dispatchers.Main.immediate, on the main thread: at once")
        assertTrue(fragment.job.isActive)
        assertSame(fragment.lifecycleScope, fragment.lifecycle.coroutineScope)
        onMain { activity.supportFragmentManager.beginTransaction().remove(fragment).commitNow() }
        assertTrue(fragment.job.isCancelled)
    }

    @Test
    fun `a generated contract's result arrives as cancelled, through its bridge`() {
        // ActivityResultContracts.OpenDocument comes from the index, as extensions get it. The launcher reads
        // its result through ActivityResultContract's erased parseResult, which only its bridge has (Task 1).
        @Suppress("UNCHECKED_CAST")
        val contract = FrameworkClassLoader(javaClass.classLoader)
            .loadClass("androidx.activity.result.contract.ActivityResultContracts\$OpenDocument")
            .getConstructor().newInstance() as ActivityResultContract<Array<String>, Any?>
        val answers = mutableListOf<Any?>()
        val launcher = Fragment().registerForActivityResult(contract) { answers += it }
        onMain { launcher.launch(arrayOf("*/*")) }
        drainMain()
        assertEquals(listOf<Any?>(null), answers)
    }
}
