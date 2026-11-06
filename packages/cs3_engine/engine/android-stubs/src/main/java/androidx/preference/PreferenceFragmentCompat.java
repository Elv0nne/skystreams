package androidx.preference;

import android.content.Context;
import android.os.Bundle;
import android.text.TextUtils;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import androidx.appcompat.app.AlertDialog;
import androidx.fragment.app.Fragment;
import androidx.recyclerview.widget.LinearLayoutManager;
import androidx.recyclerview.widget.RecyclerView;
import dev.akash.cs3engine.stubs.MainThread;
import dev.akash.cs3engine.stubs.Ui;

/**
 * A fragment that shows a preference screen as Android's does: a list of the screen's rows. Text and list
 * preferences open the alerts androidx.preference's dialog fragments show, owned by this fragment (Ui.own),
 * so their windows are its extension's. Screens aren't read from XML: an extension's resources aren't the
 * app's, so Android couldn't read them either.
 */
public abstract class PreferenceFragmentCompat extends Fragment
    implements PreferenceManager.OnPreferenceTreeClickListener, PreferenceManager.OnDisplayPreferenceDialogListener {
    public static final String ARG_PREFERENCE_ROOT = "androidx.preference.PreferenceFragmentCompat.PREFERENCE_ROOT";

    private PreferenceManager preferenceManager;
    private RecyclerView list;
    private boolean havePrefs;
    private boolean initDone;
    private boolean bindPosted;
    private AlertDialog openDialog;

    public PreferenceFragmentCompat() {}

    @Override public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        preferenceManager = new PreferenceManager(requireContext());
        Bundle args = getArguments();
        onCreatePreferences(savedInstanceState, args != null ? args.getString(ARG_PREFERENCE_ROOT) : null);
    }

    public abstract void onCreatePreferences(Bundle savedInstanceState, String rootKey);

    /** preference_list_fragment: a column whose list container (weight 1) holds the list. */
    @Override public View onCreateView(LayoutInflater inflater, ViewGroup container, Bundle savedInstanceState) {
        Context context = requireContext();
        LinearLayout root = new LinearLayout(context);
        root.setOrientation(LinearLayout.VERTICAL);
        FrameLayout listContainer = new FrameLayout(context);
        list = onCreateRecyclerView(inflater, listContainer, savedInstanceState);
        listContainer.addView(list);
        root.addView(listContainer, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));
        return root;
    }

    public RecyclerView onCreateRecyclerView(LayoutInflater inflater, ViewGroup parent, Bundle savedInstanceState) {
        RecyclerView recyclerView = new RecyclerView(parent.getContext());
        recyclerView.setLayoutManager(onCreateLayoutManager());
        return recyclerView;
    }

    public RecyclerView.LayoutManager onCreateLayoutManager() { return new LinearLayoutManager(requireContext()); }

    @Override public void onViewCreated(View view, Bundle savedInstanceState) {
        super.onViewCreated(view, savedInstanceState);
        if (havePrefs) bindPreferences();
        initDone = true;
    }

    @Override public void onStart() {
        super.onStart();
        preferenceManager.setOnPreferenceTreeClickListener(this);
        preferenceManager.setOnDisplayPreferenceDialogListener(this);
    }

    @Override public void onStop() {
        super.onStop();
        preferenceManager.setOnPreferenceTreeClickListener(null);
        preferenceManager.setOnDisplayPreferenceDialogListener(null);
    }

    @Override public void onDestroyView() {
        if (havePrefs) unbindPreferences();
        if (openDialog != null) openDialog.dismiss();
        list = null;
        super.onDestroyView();
    }

    public PreferenceManager getPreferenceManager() { return preferenceManager; }
    public PreferenceScreen getPreferenceScreen() { return preferenceManager.getPreferenceScreen(); }

    /** The screen to show: bound when the view is made, or after the current main-thread task once it is. */
    public void setPreferenceScreen(PreferenceScreen preferenceScreen) {
        if (!preferenceManager.setPreferences(preferenceScreen) || preferenceScreen == null) return;
        onUnbindPreferences();
        havePrefs = true;
        if (initDone) postBindPreferences();
    }

    public <T extends Preference> T findPreference(CharSequence key) {
        return preferenceManager == null ? null : preferenceManager.findPreference(key);
    }

    public final RecyclerView getListView() { return list; }
    protected RecyclerView.Adapter onCreateAdapter(PreferenceScreen preferenceScreen) { return new PreferenceGroupAdapter(preferenceScreen); }
    protected void onBindPreferences() {}
    protected void onUnbindPreferences() {}
    @Override public boolean onPreferenceTreeClick(Preference preference) { return false; }

    @Override public void onDisplayPreferenceDialog(Preference preference) {
        if (openDialog != null && openDialog.isShowing()) return;
        if (preference instanceof EditTextPreference) {
            showTextDialog((EditTextPreference) preference);
        } else if (preference instanceof ListPreference) {
            showListDialog((ListPreference) preference);
        } else {
            throw new IllegalArgumentException("Cannot display dialog for an unknown Preference type: " + preference.getClass().getSimpleName()
                + ". Make sure to implement onPreferenceDisplayDialog() to handle displaying a custom dialog for this Preference.");
        }
    }

    private void postBindPreferences() {
        if (bindPosted) return;
        bindPosted = true;
        MainThread.post(() -> {
            bindPosted = false;
            bindPreferences();
        });
    }

    private void bindPreferences() {
        PreferenceScreen screen = getPreferenceScreen();
        if (screen != null && list != null) {
            list.setAdapter(onCreateAdapter(screen));
            screen.onAttached();
        }
        onBindPreferences();
    }

    private void unbindPreferences() {
        PreferenceScreen screen = getPreferenceScreen();
        if (screen != null) screen.onDetached();
        onUnbindPreferences();
    }

    /** preference_dialog_edittext: the message (hidden when there's none) over the field; Cancel, then OK, which saves. */
    private void showTextDialog(EditTextPreference preference) {
        Context context = requireContext();
        LinearLayout content = new LinearLayout(context);
        content.setOrientation(LinearLayout.VERTICAL);
        TextView message = new TextView(context);
        message.setId(android.R.id.message);
        CharSequence dialogMessage = preference.getDialogMessage();
        message.setText(TextUtils.isEmpty(dialogMessage) ? "" : dialogMessage);
        message.setVisibility(TextUtils.isEmpty(dialogMessage) ? View.GONE : View.VISIBLE);
        content.addView(message);
        EditText edit = new EditText(context);
        edit.setId(android.R.id.edit);
        edit.setText(preference.getText() == null ? "" : preference.getText());
        edit.setSelection(edit.getText().length());
        content.addView(edit);
        if (preference.getOnBindEditTextListener() != null) preference.getOnBindEditTextListener().onBindEditText(edit);
        ScrollView scroll = new ScrollView(context);
        scroll.addView(content);
        show(new AlertDialog.Builder(context)
            .setTitle(preference.getDialogTitle())
            .setView(scroll)
            .setPositiveButton(preference.getPositiveButtonText(), (dialog, which) -> {
                String value = edit.getText().toString();
                if (preference.callChangeListener(value)) preference.setText(value);
            })
            .setNegativeButton(preference.getNegativeButtonText(), null)
            .create());
    }

    /** The choices, the current one checked; picking one saves it and closes the alert. Cancel only. */
    private void showListDialog(ListPreference preference) {
        CharSequence[] entries = preference.getEntries();
        CharSequence[] values = preference.getEntryValues();
        if (entries == null || values == null) throw new IllegalStateException("ListPreference requires an entries array and an entryValues array.");
        show(new AlertDialog.Builder(requireContext())
            .setTitle(preference.getDialogTitle())
            .setSingleChoiceItems(entries, preference.findIndexOfValue(preference.getValue()), (dialog, which) -> {
                String value = values[which].toString();
                if (preference.callChangeListener(value)) preference.setValue(value);
                dialog.dismiss();
            })
            .setNegativeButton(preference.getNegativeButtonText(), null)
            .create());
    }

    private void show(AlertDialog dialog) {
        openDialog = dialog;
        Ui.own(dialog, this);
        dialog.show();
    }
}
