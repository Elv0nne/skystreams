package androidx.appcompat.app;

import android.content.Context;
import android.content.DialogInterface;
import android.graphics.drawable.Drawable;
import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.widget.AdapterView;
import android.widget.Button;
import android.widget.ListAdapter;
import android.widget.ListView;
import dev.akash.cs3engine.stubs.AlertContent;

/** AppCompat's alert: its title, message, items or view, and buttons (AlertContent). */
public class AlertDialog extends AppCompatDialog implements DialogInterface {
    private final AlertContent alert;

    protected AlertDialog(Context context) {
        this(context, 0);
    }

    protected AlertDialog(Context context, int themeResId) {
        super(context, themeResId);
        alert = new AlertContent(context, this);
    }

    protected AlertDialog(Context context, boolean cancelable, OnCancelListener cancelListener) {
        super(context, cancelable, cancelListener);
        alert = new AlertContent(context, this);
    }

    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(alert.build());
    }

    @Override protected String cs3Kind() { return "alert"; }
    public Button getButton(int whichButton) { return alert.button(whichButton); }
    public ListView getListView() { return alert.list(); }
    @Override public void setTitle(CharSequence title) { alert.setTitle(title); }
    public void setCustomTitle(View customTitleView) { alert.setCustomTitle(customTitleView); }
    public void setMessage(CharSequence message) { alert.setMessage(message); }
    public void setView(View view) { alert.setView(view); }
    public void setView(View view, int viewSpacingLeft, int viewSpacingTop, int viewSpacingRight, int viewSpacingBottom) { alert.setView(view); }
    public void setButton(int whichButton, CharSequence text, OnClickListener listener) { alert.setButton(whichButton, text, listener); }
    public void setButton(int whichButton, CharSequence text, Drawable icon, OnClickListener listener) { alert.setButton(whichButton, text, listener); }
    public void setIcon(int resId) {}
    public void setIcon(Drawable icon) {}

    public static class Builder {
        private final Context context;
        private final AlertContent.Params p = new AlertContent.Params();

        public Builder(Context context) {
            this(context, 0);
        }

        public Builder(Context context, int themeResId) {
            this.context = context;
        }

        public Context getContext() { return context; }
        public Builder setTitle(int titleId) { p.title = context.getString(titleId); return this; }
        public Builder setTitle(CharSequence title) { p.title = title; return this; }
        public Builder setCustomTitle(View customTitleView) { p.customTitle = customTitleView; return this; }
        public Builder setMessage(int messageId) { p.message = context.getString(messageId); return this; }
        public Builder setMessage(CharSequence message) { p.message = message; return this; }
        public Builder setIcon(int iconId) { return this; }
        public Builder setIcon(Drawable icon) { return this; }
        public Builder setIconAttribute(int attrId) { return this; }
        public Builder setPositiveButton(int textId, OnClickListener listener) { return setPositiveButton(context.getString(textId), listener); }
        public Builder setPositiveButton(CharSequence text, OnClickListener listener) { return button(BUTTON_POSITIVE, text, listener); }
        public Builder setPositiveButtonIcon(Drawable icon) { return this; }
        public Builder setNegativeButton(int textId, OnClickListener listener) { return setNegativeButton(context.getString(textId), listener); }
        public Builder setNegativeButton(CharSequence text, OnClickListener listener) { return button(BUTTON_NEGATIVE, text, listener); }
        public Builder setNegativeButtonIcon(Drawable icon) { return this; }
        public Builder setNeutralButton(int textId, OnClickListener listener) { return setNeutralButton(context.getString(textId), listener); }
        public Builder setNeutralButton(CharSequence text, OnClickListener listener) { return button(BUTTON_NEUTRAL, text, listener); }
        public Builder setNeutralButtonIcon(Drawable icon) { return this; }

        private Builder button(int which, CharSequence text, OnClickListener listener) {
            p.buttonText[AlertContent.Params.index(which)] = text;
            p.buttonListener[AlertContent.Params.index(which)] = listener;
            return this;
        }

        public Builder setCancelable(boolean cancelable) { p.cancelable = cancelable; return this; }
        public Builder setOnCancelListener(OnCancelListener listener) { p.onCancel = listener; return this; }
        public Builder setOnDismissListener(OnDismissListener listener) { p.onDismiss = listener; return this; }
        public Builder setOnKeyListener(OnKeyListener listener) { p.onKey = listener; return this; }
        public Builder setItems(int itemsId, OnClickListener listener) { return setItems(context.getResources().getTextArray(itemsId), listener); }
        public Builder setItems(CharSequence[] items, OnClickListener listener) { p.items = items; p.itemsListener = listener; return this; }
        public Builder setAdapter(ListAdapter adapter, OnClickListener listener) { p.adapter = adapter; p.itemsListener = listener; return this; }

        public Builder setMultiChoiceItems(int itemsId, boolean[] checkedItems, OnMultiChoiceClickListener listener) {
            return setMultiChoiceItems(context.getResources().getTextArray(itemsId), checkedItems, listener);
        }

        public Builder setMultiChoiceItems(CharSequence[] items, boolean[] checkedItems, OnMultiChoiceClickListener listener) {
            p.items = items;
            p.checkedItems = checkedItems;
            p.multiListener = listener;
            return this;
        }

        public Builder setSingleChoiceItems(int itemsId, int checkedItem, OnClickListener listener) {
            return setSingleChoiceItems(context.getResources().getTextArray(itemsId), checkedItem, listener);
        }

        public Builder setSingleChoiceItems(CharSequence[] items, int checkedItem, OnClickListener listener) {
            p.items = items;
            p.singleChoice = true;
            p.checkedItem = checkedItem;
            p.itemsListener = listener;
            return this;
        }

        public Builder setSingleChoiceItems(ListAdapter adapter, int checkedItem, OnClickListener listener) {
            p.adapter = adapter;
            p.singleChoice = true;
            p.checkedItem = checkedItem;
            p.itemsListener = listener;
            return this;
        }

        public Builder setOnItemSelectedListener(AdapterView.OnItemSelectedListener listener) { return this; }
        public Builder setView(int layoutResId) { p.view = LayoutInflater.from(context).inflate(layoutResId, null); return this; }
        public Builder setView(View view) { p.view = view; return this; }
        public Builder setView(View view, int viewSpacingLeft, int viewSpacingTop, int viewSpacingRight, int viewSpacingBottom) { p.view = view; return this; }
        public Builder setInverseBackgroundForced(boolean useInverseBackground) { return this; }
        public Builder setRecycleOnMeasureEnabled(boolean enabled) { return this; }

        public AlertDialog create() {
            AlertDialog dialog = new AlertDialog(context, 0);
            p.applyTo(dialog, dialog.alert);
            return dialog;
        }

        public AlertDialog show() {
            AlertDialog dialog = create();
            dialog.show();
            return dialog;
        }
    }
}
