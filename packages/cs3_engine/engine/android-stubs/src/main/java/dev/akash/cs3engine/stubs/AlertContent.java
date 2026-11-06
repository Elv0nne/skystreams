package dev.akash.cs3engine.stubs;

import android.app.Dialog;
import android.content.Context;
import android.content.DialogInterface;
import android.view.View;
import android.view.ViewGroup;
import android.widget.AbsListView;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ListAdapter;
import android.widget.ListView;
import android.widget.Space;
import android.widget.TextView;

/**
 * An alert's views, as Android's alert layout arranges them: the title (or a custom one), the message, its
 * items or its own view, then neutral, negative and positive buttons. Both AlertDialogs and their builders
 * fill it; it's built when the dialog is created.
 */
public final class AlertContent {
    /** What a builder keeps until create(). */
    public static final class Params {
        public CharSequence title;
        public View customTitle;
        public CharSequence message;
        public View view;
        public CharSequence[] items;
        public ListAdapter adapter;
        public DialogInterface.OnClickListener itemsListener;
        public boolean singleChoice;
        public int checkedItem = -1;
        public boolean[] checkedItems;
        public DialogInterface.OnMultiChoiceClickListener multiListener;
        public final CharSequence[] buttonText = new CharSequence[3];
        public final DialogInterface.OnClickListener[] buttonListener = new DialogInterface.OnClickListener[3];
        public boolean cancelable = true;
        public DialogInterface.OnCancelListener onCancel;
        public DialogInterface.OnDismissListener onDismiss;
        public DialogInterface.OnKeyListener onKey;

        /** [which] (BUTTON_POSITIVE -1, NEGATIVE -2, NEUTRAL -3) as an index. */
        public static int index(int which) { return -which - 1; }

        public void applyTo(Dialog dialog, AlertContent alert) {
            alert.title = title;
            alert.customTitle = customTitle;
            alert.message = message;
            alert.view = view;
            alert.items = items;
            alert.adapter = adapter;
            alert.itemsListener = itemsListener;
            alert.singleChoice = singleChoice;
            alert.checkedItem = checkedItem;
            alert.checkedItems = checkedItems;
            alert.multiListener = multiListener;
            for (int i = 0; i < 3; i++) {
                alert.buttonText[i] = buttonText[i];
                alert.buttonListener[i] = buttonListener[i];
            }
            dialog.setCancelable(cancelable);
            dialog.setOnCancelListener(onCancel);
            dialog.setOnDismissListener(onDismiss);
            dialog.setOnKeyListener(onKey);
        }
    }

    private final Context context;
    private final Dialog dialog;
    private CharSequence title;
    private View customTitle;
    private CharSequence message;
    private View view;
    private CharSequence[] items;
    private ListAdapter adapter;
    private DialogInterface.OnClickListener itemsListener;
    private boolean singleChoice;
    private int checkedItem = -1;
    private boolean[] checkedItems;
    private DialogInterface.OnMultiChoiceClickListener multiListener;
    private final CharSequence[] buttonText = new CharSequence[3];
    private final DialogInterface.OnClickListener[] buttonListener = new DialogInterface.OnClickListener[3];
    private final Button[] buttons = new Button[3];
    private TextView titleView;
    private TextView messageView;
    private ListView list;

    public AlertContent(Context context, Dialog dialog) {
        this.context = context;
        this.dialog = dialog;
    }

    public void setTitle(CharSequence title) {
        this.title = title;
        if (titleView != null) titleView.setText(title);
    }

    public void setCustomTitle(View customTitle) { this.customTitle = customTitle; }

    public void setMessage(CharSequence message) {
        this.message = message;
        if (messageView != null) messageView.setText(message);
    }

    public void setView(View view) { this.view = view; }

    public void setButton(int which, CharSequence text, DialogInterface.OnClickListener listener) {
        buttonText[Params.index(which)] = text;
        buttonListener[Params.index(which)] = listener;
    }

    public Button button(int which) {
        int index = Params.index(which);
        return index >= 0 && index < 3 ? buttons[index] : null;
    }

    public ListView list() { return list; }

    /** The alert's views, built once. */
    public View build() {
        LinearLayout root = new LinearLayout(context);
        root.setOrientation(LinearLayout.VERTICAL);
        if (customTitle != null) {
            detach(customTitle);
            root.addView(customTitle);
        } else if (title != null && title.length() > 0) {
            titleView = new TextView(context);
            titleView.setTextSize(20f);
            titleView.setText(title);
            root.addView(titleView);
        }
        if (message != null) {
            messageView = new TextView(context);
            messageView.setId(android.R.id.message);
            messageView.setText(message);
            root.addView(messageView);
        }
        if (items != null || adapter != null) {
            // Android's alert shows its list only when it has no message (AlertController.setupContent); the list
            // is the alert's either way (getListView).
            ListView built = buildList();
            if (message == null) root.addView(built);
        }
        if (view != null) {
            detach(view);
            root.addView(view);
        }
        LinearLayout row = new LinearLayout(context);
        row.setOrientation(LinearLayout.HORIZONTAL);
        addButton(row, DialogInterface.BUTTON_NEUTRAL, android.R.id.button3);
        if (buttonText[Params.index(DialogInterface.BUTTON_NEUTRAL)] != null) row.addView(new Space(context));
        addButton(row, DialogInterface.BUTTON_NEGATIVE, android.R.id.button2);
        addButton(row, DialogInterface.BUTTON_POSITIVE, android.R.id.button1);
        if (row.getChildCount() > 0) root.addView(row);
        return root;
    }

    private void addButton(LinearLayout row, int which, int id) {
        int index = Params.index(which);
        if (buttonText[index] == null) return;
        Button button = new Button(context);
        button.setId(id);
        button.setText(buttonText[index]);
        // As Android's: the button answers, then the alert closes.
        button.setOnClickListener(v -> {
            DialogInterface.OnClickListener listener = buttonListener[index];
            if (listener != null) listener.onClick(dialog, which);
            dialog.dismiss();
        });
        buttons[index] = button;
        row.addView(button);
    }

    private ListView buildList() {
        list = new ListView(context);
        ListAdapter shown = adapter != null ? adapter : new ArrayAdapter<>(context, android.R.layout.select_dialog_item, items);
        list.setAdapter(shown);
        if (multiListener != null || checkedItems != null) {
            list.setChoiceMode(AbsListView.CHOICE_MODE_MULTIPLE);
            if (checkedItems != null) for (int i = 0; i < checkedItems.length; i++) if (checkedItems[i]) list.setItemChecked(i, true);
        } else if (singleChoice) {
            list.setChoiceMode(AbsListView.CHOICE_MODE_SINGLE);
            if (checkedItem >= 0) list.setItemChecked(checkedItem, true);
        }
        list.setOnItemClickListener((parent, item, position, id) -> {
            if (list.getChoiceMode() == AbsListView.CHOICE_MODE_MULTIPLE) {
                boolean on = list.isItemChecked(position);
                if (checkedItems != null && position < checkedItems.length) checkedItems[position] = on;
                if (multiListener != null) multiListener.onClick(dialog, position, on);
                return;
            }
            if (itemsListener != null) itemsListener.onClick(dialog, position);
            if (!singleChoice) dialog.dismiss();
        });
        return list;
    }

    private static void detach(View view) {
        if (view.getParent() instanceof ViewGroup) ((ViewGroup) view.getParent()).removeView(view);
    }
}
