package dev.akash.cs3engine.stubs

import android.app.Dialog
import android.content.Context
import android.content.DialogInterface
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import com.google.android.material.bottomsheet.BottomSheetBehavior
import com.google.android.material.bottomsheet.BottomSheetDialog
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** Every TextView's words under [root], in order. */
fun texts(root: View): List<String> = when (root) {
    is TextView -> listOf(root.text.toString())
    is ViewGroup -> (0 until root.childCount).flatMap { texts(root.getChildAt(it)) }
    else -> emptyList()
}

class DialogsTest {
    private val context = Context()

    @AfterTest
    fun clear() {
        Ui.windows().forEach { Ui.dismissed(it.owner) }
    }

    @Test
    fun `a dialog's window registers when shown and leaves when dismissed, its listeners told`() {
        val heard = mutableListOf<String>()
        val dialog = Dialog(context)
        dialog.setContentView(TextView(context).apply { text = "hi" })
        dialog.setOnShowListener { heard += "shown" }
        dialog.setOnDismissListener { heard += "dismissed" }
        dialog.show()
        val window = Ui.windows().single()
        assertSame(dialog, window.owner)
        assertEquals("dialog", window.kind)
        assertSame(dialog.window.decorView, window.root)
        assertTrue(dialog.isShowing)
        drainMain()
        dialog.dismiss()
        assertTrue(Ui.windows().isEmpty())
        assertEquals(listOf("shown", "dismissed"), heard)
        assertSame(dialog.findViewById<View>(android.R.id.content), (dialog.window.decorView as ViewGroup).getChildAt(0), "no title: the content frame first")
    }

    @Test
    fun `Back cancels a cancelable dialog, and only that`() {
        val dialog = Dialog(context)
        var cancels = 0
        dialog.setOnCancelListener { cancels++ }
        dialog.setCancelable(false)
        dialog.show()
        dialog.onBackPressed()
        assertTrue(dialog.isShowing)
        assertFalse(dialog.cs3Cancelable())
        dialog.setCancelable(true)
        dialog.onBackPressed()
        assertFalse(dialog.isShowing)
        assertEquals(1, cancels)
    }

    @Test
    fun `a plain dialog shows its title above its content, as Android's do`() {
        val dialog = Dialog(context)
        dialog.setContentView(TextView(context).apply { text = "body" })
        dialog.setTitle("Restart required")
        assertEquals(listOf("Restart required", "body"), texts(dialog.window.decorView))
        val title = (dialog.window.decorView as ViewGroup).getChildAt(0) as TextView
        assertEquals(40f, title.textSize, "20sp: a heading")
    }

    @Test
    fun `an alert builds Android's layout — title, message, then No before Yes, and a button answers and closes it`() {
        var answer = 0
        val dialog = AlertDialog.Builder(context)
            .setTitle("Restart required")
            .setMessage("Restart the app to apply the changes?")
            .setPositiveButton("Yes") { _, which -> answer = which }
            .setNegativeButton("No", null)
            .show()
        assertEquals("alert", Ui.windows().single().kind)
        assertEquals(listOf("Restart required", "Restart the app to apply the changes?", "No", "Yes"), texts(dialog.window.decorView))
        assertEquals("Restart the app to apply the changes?", dialog.findViewById<TextView>(android.R.id.message)!!.text.toString())
        val yes = assertNotNull(dialog.getButton(DialogInterface.BUTTON_POSITIVE))
        assertSame(yes, dialog.findViewById<Button>(android.R.id.button1))
        yes.performClick()
        assertEquals(DialogInterface.BUTTON_POSITIVE, answer)
        assertFalse(dialog.isShowing)
    }

    @Test
    fun `an alert's items are a list, a plain item answers and closes it, a choice doesn't close it`() {
        var picked = -1
        val plain = AlertDialog.Builder(context).setItems(arrayOf("a", "b")) { _, which -> picked = which }.show()
        val list = plain.listView
        assertEquals(2, list.childCount)
        list.performItemClick(list.getChildAt(1), 1, 1)
        assertEquals(1, picked)
        assertFalse(plain.isShowing)

        var chosen = -1
        val single = AlertDialog.Builder(context).setSingleChoiceItems(arrayOf("x", "y"), 0) { _, which -> chosen = which }.show()
        single.listView.performItemClick(single.listView.getChildAt(1), 1, 1)
        assertEquals(1, chosen)
        assertTrue(single.isShowing)
        assertEquals(1, single.listView.checkedItemPosition)
        single.dismiss()

        val checked = booleanArrayOf(false, true)
        val toggles = mutableListOf<Pair<Int, Boolean>>()
        val multi = AlertDialog.Builder(context).setMultiChoiceItems(arrayOf("p", "q"), checked) { _, which, on -> toggles += which to on }.show()
        multi.listView.performItemClick(multi.listView.getChildAt(0), 0, 0)
        assertEquals(listOf(0 to true), toggles)
        assertTrue(checked[0], "the extension's array follows, as Android's does")
        multi.dismiss()
    }

    @Test
    fun `an alert with a message shows the message, not its items, as Android's does`() {
        // Android's AlertController puts the list in only when there's no message (AniVortex's debug menu sets both,
        // and Android shows its title, message and Cancel). The list is still the alert's, as getListView() says.
        val alert = AlertDialog.Builder(context)
            .setTitle("Debug")
            .setMessage("Registered: NO")
            .setItems(arrayOf("Register", "Clear")) { _, _ -> }
            .setNegativeButton("Cancel", null)
            .show()
        assertEquals(listOf("Debug", "Registered: NO", "Cancel"), texts(alert.window.decorView))
        assertEquals(2, alert.listView.count)
        alert.dismiss()
    }

    @Test
    fun `Android's own alert builds the same`() {
        val dialog = android.app.AlertDialog.Builder(context)
            .setTitle("Pick one")
            .setPositiveButton("OK", null)
            .setNeutralButton("Later", null)
            .create()
        dialog.show()
        assertEquals(listOf("Pick one", "Later", "OK"), texts(dialog.window.decorView))
        assertEquals("alert", Ui.windows().single().kind)
    }

    @Test
    fun `a bottom sheet holds its content in Material's sheet, which its behaviour drives`() {
        val sheet = BottomSheetDialog(context)
        val content = LinearLayout(context)
        sheet.setContentView(content)
        sheet.setTitle("ignored")
        val frame = sheet.findViewById<FrameLayout>(com.google.android.material.R.id.design_bottom_sheet)!!
        assertSame(frame, content.parent)
        assertEquals(emptyList(), texts(sheet.window.decorView), "a bottom sheet shows no title")
        sheet.show()
        assertEquals("sheet", Ui.windows().single().kind)
        val behavior = BottomSheetBehavior.from(frame)
        assertSame(sheet.behavior, behavior)
        behavior.state = BottomSheetBehavior.STATE_EXPANDED
        assertEquals(BottomSheetBehavior.STATE_EXPANDED, behavior.state)
        assertFailsWith<IllegalArgumentException> { BottomSheetBehavior.from(content) }
        behavior.state = BottomSheetBehavior.STATE_HIDDEN
        assertFalse(sheet.isShowing, "hidden by its behaviour, it closes")
    }

    @Test
    fun `a window keeps what extensions set on it`() {
        val window = Dialog(context).window
        window.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        window.addFlags(0x2)
        window.setDimAmount(0.3f)
        val attributes: WindowManager.LayoutParams = window.attributes
        assertEquals(ViewGroup.LayoutParams.WRAP_CONTENT, attributes.height)
        assertEquals(0x2, attributes.flags and 0x2)
        assertEquals(0.3f, attributes.dimAmount)
        window.clearFlags(0x2)
        assertEquals(0, attributes.flags and 0x2)
    }
}
