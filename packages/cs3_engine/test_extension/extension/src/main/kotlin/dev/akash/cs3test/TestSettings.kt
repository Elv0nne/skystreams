package dev.akash.cs3test

import android.content.Context
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.RadioGroup
import android.widget.SeekBar
import android.widget.Spinner
import android.widget.Switch
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.bottomsheet.BottomSheetDialogFragment

/** The test extension's settings: a Material bottom sheet from its own layout, as most extensions' are. */
class TestSettings(private val plugin: TestPlugin) : BottomSheetDialogFragment() {
    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View =
        inflater.inflate(plugin.resources!!.getLayout(plugin.id("layout", "test_settings")), container, false)

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val res = plugin.resources!!
        fun <T : View> find(name: String): T = view.findViewById(plugin.id("id", name))
        val prefs = requireContext().getSharedPreferences(TestPlugin.PREFS, Context.MODE_PRIVATE)
        fun text(name: String) = res.getString(plugin.id("string", name))
        // The words come from the extension's own strings, by name: a layout's @string references would
        // resolve against the app's resources, which inflate it.
        find<TextView>("title").text = text("title")
        find<ImageButton>("close").contentDescription = text("close")
        find<TextView>("second_label").text = text("second_provider")
        find<TextView>("token_label").text = text("token_label")
        find<TextView>("fast").text = text("fast")
        find<TextView>("careful").text = text("careful")
        find<TextView>("timeout_label").text = text("timeout_label")
        find<TextView>("picked").text = text("picked")
        find<TextView>("save").text = text("save")
        find<TextView>("save_activity").text = text("save_activity")

        val second = find<CheckBox>("second").apply { isChecked = prefs.getBoolean(TestPlugin.SECOND, true) }
        find<TextView>("second_label").setOnClickListener { second.toggle() }
        val dark = find<Switch>("dark").apply {
            text = text("dark_posters")
            isChecked = prefs.getBoolean("dark", false)
        }
        val token = find<EditText>("token").apply {
            hint = text("token_hint")
            setText(prefs.getString("token", ""))
        }
        val quality = find<Spinner>("quality").apply {
            adapter = ArrayAdapter(requireContext(), android.R.layout.simple_spinner_item, res.getStringArray(plugin.id("array", "qualities")))
            setSelection(prefs.getInt("quality", 0))
        }
        val mode = find<RadioGroup>("mode").apply { check(plugin.id("id", prefs.getString("mode", "fast")!!)) }
        val timeoutLabel = find<TextView>("timeout_label")
        val timeout = find<SeekBar>("timeout").apply {
            progress = prefs.getInt("timeout", 30)
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(bar: SeekBar, value: Int, fromUser: Boolean) {
                    if (fromUser) timeoutLabel.text = "Timeout: $value s"
                }

                override fun onStartTrackingTouch(bar: SeekBar) {}

                override fun onStopTrackingTouch(bar: SeekBar) {}
            })
        }
        val picked = find<TextView>("picked")
        find<RecyclerView>("items").apply {
            layoutManager = LinearLayoutManager(requireContext())
            adapter = Items(40) { position -> picked.text = "Picked: Item ${position + 1}" }
        }
        find<ImageButton>("close").setOnClickListener { dismiss() }

        fun save() = prefs.edit()
            .putBoolean(TestPlugin.SECOND, second.isChecked)
            .putBoolean("dark", dark.isChecked)
            .putString("token", token.text.toString())
            .putInt("quality", quality.selectedItemPosition)
            .putString("mode", if (mode.checkedRadioButtonId == plugin.id("id", "careful")) "careful" else "fast")
            .putInt("timeout", timeout.progress)
            .apply()

        find<Button>("save").setOnClickListener {
            save()
            AlertDialog.Builder(requireContext())
                .setTitle(res.getString(plugin.id("string", "restart_title")))
                .setMessage(res.getString(plugin.id("string", "restart_message")))
                .setPositiveButton("Yes") { _, _ -> restartThroughAppContext(requireContext()) }
                .setNegativeButton("No") { _, _ -> dismiss() }
                .show()
        }
        find<Button>("save_activity").setOnClickListener {
            save()
            restartThroughActivity(requireActivity())
        }

        // The sign-in (part 5), built here: AxmlTest pins the layout's tags.
        val signedIn = TextView(requireContext()).apply { text = prefs.getString("signed_in", null) ?: "Signed out" }
        (view as ViewGroup).addView(
            LinearLayout(requireContext()).apply {
                orientation = LinearLayout.VERTICAL
                addView(
                    Button(requireContext()).apply {
                        text = "Sign in to the test site"
                        setOnClickListener { SignIn.open(requireActivity(), prefs) { line -> signedIn.text = line } }
                    },
                )
                addView(signedIn)
            },
        )
    }

    /** Forty items; a tap reports the item from its holder's position, as real lists do. */
    private class Items(private val count: Int, private val picked: (Int) -> Unit) : RecyclerView.Adapter<Items.Holder>() {
        class Holder(val text: TextView) : RecyclerView.ViewHolder(text)

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) =
            Holder(TextView(parent.context).apply { setPadding(24, 24, 24, 24) })

        override fun onBindViewHolder(holder: Holder, position: Int) {
            holder.text.text = "Item ${position + 1}"
            holder.text.setOnClickListener { picked(holder.bindingAdapterPosition) }
        }

        override fun getItemCount() = count
    }
}
