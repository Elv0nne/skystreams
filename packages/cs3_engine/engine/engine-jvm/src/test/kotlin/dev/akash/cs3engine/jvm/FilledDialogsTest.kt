package dev.akash.cs3engine.jvm

import android.content.Context
import android.content.DialogInterface
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import java.lang.invoke.MethodHandles
import java.lang.invoke.MethodType
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertSame

class FilledDialogsTest {
    private fun texts(root: View): List<String> = when (root) {
        is TextView -> listOf(root.text.toString())
        is ViewGroup -> (0 until root.childCount).flatMap { texts(root.getChildAt(it)) }
        else -> emptyList()
    }

    @Test
    fun `Material's builder keeps its title and buttons through its narrowed setters`() {
        // An extension compiled against Material calls the setters that return MaterialAlertDialogBuilder: the
        // fill's covariant overrides, which must reach the stand-in, not drop the title as a no-op would. A call
        // site links only the method it names, and so do these lookups (Java reflection over the whole class
        // would also resolve Android's setCursor(Cursor, …), whose Cursor only extensions' loaders make).
        val builder = MaterialAlertDialogBuilder(Context())
        val type = MaterialAlertDialogBuilder::class.java
        val lookup = MethodHandles.publicLookup()
        val setTitle = lookup.findVirtual(type, "setTitle", MethodType.methodType(type, CharSequence::class.java))
        assertSame(builder, setTitle.invoke(builder, "Restart required"))
        val clicks = MethodType.methodType(type, CharSequence::class.java, DialogInterface.OnClickListener::class.java)
        val positive = lookup.findVirtual(type, "setPositiveButton", clicks)
        assertSame(builder, positive.invoke(builder, "Yes", null as DialogInterface.OnClickListener?))
        val dialog = builder.create() as AlertDialog
        dialog.show()
        assertEquals(listOf("Restart required", "Yes"), texts(dialog.window.decorView))
        dialog.dismiss()
    }
}
