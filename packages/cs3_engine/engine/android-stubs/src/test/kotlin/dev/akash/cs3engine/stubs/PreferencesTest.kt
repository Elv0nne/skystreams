package dev.akash.cs3engine.stubs

import android.content.Context
import android.content.DialogInterface
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.SeekBar
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.SwitchCompat
import androidx.fragment.app.FragmentContainerView
import androidx.preference.EditTextPreference
import androidx.preference.ListPreference
import androidx.preference.Preference
import androidx.preference.PreferenceCategory
import androidx.preference.PreferenceDataStore
import androidx.preference.PreferenceFragmentCompat
import androidx.preference.PreferenceGroupAdapter
import androidx.preference.PreferenceManager
import androidx.preference.SeekBarPreference
import androidx.preference.SwitchPreferenceCompat
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.bottomsheet.BottomSheetDialogFragment
import java.util.UUID
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** A preference screen built in code, as the corpus' three are, in shared preferences of its own. */
class Prefs(private val build: PreferenceFragmentCompat.() -> Unit) : PreferenceFragmentCompat() {
    override fun onCreatePreferences(savedInstanceState: Bundle?, rootKey: String?) {
        preferenceManager.sharedPreferencesName = "prefs-test-" + UUID.randomUUID()
        build()
    }
}

/** Cinemana's shape: a bottom sheet whose view is a container its child manager puts the screen in. */
class PrefsSheet(build: PreferenceFragmentCompat.() -> Unit) : BottomSheetDialogFragment() {
    val prefs = Prefs(build)

    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View =
        FragmentContainerView(requireContext()).apply { id = View.generateViewId() }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        childFragmentManager.beginTransaction().replace(view.id, prefs).commit()
    }
}

class PreferencesTest {
    private val context = Context()
    private val activity = AppCompatActivity()
    private val manager = PreferenceManager(context).apply { sharedPreferencesName = "prefs-test-" + UUID.randomUUID() }

    @AfterTest
    fun clear() {
        Ui.windows().forEach { Ui.dismissed(it.owner) }
    }

    private fun show(build: PreferenceFragmentCompat.() -> Unit): PrefsSheet {
        val sheet = PrefsSheet(build)
        sheet.show(activity.supportFragmentManager, "settings")
        drainMain()
        return sheet
    }

    @Test
    fun `a switch starts from its saved value or saves its default, and a tap saves the new one unless its listener says no`() {
        manager.sharedPreferences!!.edit().putBoolean("saved", false).commit()
        val screen = manager.createPreferenceScreen(context)
        val saved = SwitchPreferenceCompat(context).apply { key = "saved"; setDefaultValue(true) }
        val fresh = SwitchPreferenceCompat(context).apply { key = "fresh"; setDefaultValue(true) }
        screen.addPreference(saved)
        screen.addPreference(fresh)
        assertFalse(saved.isChecked, "the saved value wins over the default")
        assertTrue(fresh.isChecked)
        assertTrue(manager.sharedPreferences!!.getBoolean("fresh", false), "the default is saved, as Android saves it")
        var allow = false
        fresh.setOnPreferenceChangeListener { _, _ -> allow }
        fresh.performClick()
        assertTrue(fresh.isChecked, "its listener said no")
        allow = true
        fresh.performClick()
        assertFalse(fresh.isChecked)
        assertFalse(manager.sharedPreferences!!.getBoolean("fresh", true))
    }

    @Test
    fun `a seek bar keeps its value in range, and its row saves what the person slides to`() {
        val screen = manager.createPreferenceScreen(context)
        val pages = SeekBarPreference(context).apply {
            key = "pages"
            min = 1
            max = 50
            showSeekBarValue = true
        }
        screen.addPreference(pages)
        pages.value = 99
        assertEquals(50, pages.value)
        val list = RecyclerView(context).apply {
            layoutManager = LinearLayoutManager(context)
            adapter = PreferenceGroupAdapter(screen)
        }
        val row = list.getChildAt(0)
        val bar = row.findViewById<SeekBar>(androidx.preference.R.id.seekbar)
        assertEquals(49, bar.max)
        assertEquals(49, bar.progress)
        Ui.acting { bar.progress = 9 }
        assertEquals(10, pages.value)
        assertEquals(10, manager.sharedPreferences!!.getInt("pages", 0))
        assertEquals("10", row.findViewById<TextView>(androidx.preference.R.id.seekbar_value).text.toString())
    }

    @Test
    fun `summary providers give Android's summaries, and a summary beside one fails as on Android`() {
        val screen = manager.createPreferenceScreen(context)
        val token = EditTextPreference(context).apply {
            key = "token"
            summaryProvider = EditTextPreference.SimpleSummaryProvider.getInstance()
        }
        val quality = ListPreference(context).apply {
            key = "quality"
            entries = arrayOf("Low", "High")
            entryValues = arrayOf("480", "1080")
            summaryProvider = ListPreference.SimpleSummaryProvider.getInstance()
        }
        screen.addPreference(token)
        screen.addPreference(quality)
        assertEquals("Not set", token.summary)
        assertEquals("Not set", quality.summary)
        token.text = "abc"
        quality.value = "1080"
        assertEquals("abc", token.summary)
        assertEquals("High", quality.summary)
        assertFailsWith<IllegalStateException> { token.summary = "mine" }
    }

    @Test
    fun `a data store keeps the values in place of the shared preferences`() {
        val stored = mutableMapOf<String, Any?>()
        manager.preferenceDataStore = object : PreferenceDataStore() {
            override fun putBoolean(key: String?, value: Boolean) {
                stored[key!!] = value
            }

            override fun getBoolean(key: String?, defValue: Boolean) = stored[key] as Boolean? ?: defValue
        }
        val screen = manager.createPreferenceScreen(context)
        val remote = SwitchPreferenceCompat(context).apply { key = "remote"; setDefaultValue(true) }
        screen.addPreference(remote)
        assertTrue(remote.isChecked)
        remote.performClick()
        assertEquals(false, stored["remote"])
        assertNull(manager.sharedPreferences)
    }

    @Test
    fun `a preference screen in a sheet is a list of rows, which taps and changes bind again`() {
        lateinit var banner: SwitchPreferenceCompat
        lateinit var extras: PreferenceCategory
        val sheet = show {
            val screen = preferenceManager.createPreferenceScreen(requireContext())
            preferenceScreen = screen
            val general = PreferenceCategory(requireContext()).apply { title = "General" }
            screen.addPreference(general)
            banner = SwitchPreferenceCompat(requireContext()).apply { key = "banner"; title = "Banner"; setDefaultValue(false) }
            general.addPreference(banner)
            extras = PreferenceCategory(requireContext()).apply { title = "Extras" }
            screen.addPreference(extras)
        }
        assertEquals("sheet", Ui.windows().single().kind)
        val list = sheet.prefs.listView
        assertEquals(3, list.childCount)
        val switch = list.getChildAt(1).findViewById<SwitchCompat>(androidx.preference.R.id.switchWidget)
        assertFalse(switch.isChecked)
        onMain { list.getChildAt(1).performClick() }
        assertTrue(banner.isChecked)
        assertTrue(switch.isChecked, "the row was bound again")
        onMain { extras.addPreference(Preference(context).apply { title = "Clear cache"; summary = "Tap to refresh" }) }
        drainMain()
        assertEquals(4, list.childCount, "a new preference: the rows were rebuilt")
        assertEquals("Tap to refresh", list.getChildAt(3).findViewById<TextView>(android.R.id.summary).text.toString())
    }

    @Test
    fun `a text preference opens Android's text alert, whose OK saves the text`() {
        lateinit var token: EditTextPreference
        var bound: EditText? = null
        val sheet = show {
            preferenceScreen = preferenceManager.createPreferenceScreen(requireContext()).also { screen ->
                token = EditTextPreference(requireContext()).apply {
                    key = "token"
                    title = "Token"
                    dialogTitle = "Paste a token"
                    setOnBindEditTextListener { bound = it }
                }
                screen.addPreference(token)
            }
        }
        onMain { sheet.prefs.listView.getChildAt(0).performClick() }
        val alert = Ui.windows().last()
        assertEquals("alert", alert.kind)
        assertSame(sheet.prefs, alert.fragment, "the alert is the screen's extension's")
        val field = assertNotNull(bound)
        assertSame(field, alert.root.findViewById<EditText>(android.R.id.edit))
        onMain {
            field.setText("abc")
            (alert.owner as AlertDialog).getButton(DialogInterface.BUTTON_POSITIVE).performClick()
        }
        assertEquals("abc", token.text)
        assertEquals(1, Ui.windows().size, "OK closed the alert")
    }

    @Test
    fun `a list preference opens its choices, and picking one saves it and closes the alert`() {
        lateinit var quality: ListPreference
        val sheet = show {
            preferenceScreen = preferenceManager.createPreferenceScreen(requireContext()).also { screen ->
                quality = ListPreference(requireContext()).apply {
                    key = "quality"
                    title = "Quality"
                    entries = arrayOf("Low", "High")
                    entryValues = arrayOf("480", "1080")
                    setDefaultValue("480")
                }
                screen.addPreference(quality)
            }
        }
        onMain { sheet.prefs.listView.getChildAt(0).performClick() }
        val alert = Ui.windows().last().owner as AlertDialog
        assertEquals(0, alert.listView.checkedItemPosition)
        onMain { alert.listView.performItemClick(alert.listView.getChildAt(1), 1, 1) }
        assertEquals("1080", quality.value)
        assertFalse(alert.isShowing)
    }
}
