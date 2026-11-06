package dev.akash.cs3engine.stubs;

import android.content.res.Resources;
import android.util.AttributeSet;
import android.util.TypedValue;
import android.view.View;
import android.widget.AdapterView;
import android.widget.ArrayAdapter;
import android.widget.CompoundButton;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.ProgressBar;
import android.widget.Spinner;
import android.widget.TextView;
import com.google.android.material.textfield.TextInputLayout;

/**
 * A layout element's attributes that carry meaning, set as Android sets them: each class's own in its constructor
 * (View's in View's, TextView's in TextView's...), so a custom view sees them in its init, and one that drops the
 * attribute set gets none. A stand-in whose constructor sets a default after its superclass's sets that level's
 * attributes again, so the layout's still win (EditText, Button, RadioGroup, SeekBar). The inflater sets them all
 * after making a view only when no stand-in constructor saw them: a class without a (Context, AttributeSet)
 * constructor, or one nothing has, which stands in empty.
 */
public final class LayoutAttributes {
    private LayoutAttributes() {}

    /** android.R.attr.progressBarStyleHorizontal and android.R.style.Widget_ProgressBar_Horizontal: a bar with a value. */
    private static final int HORIZONTAL_PROGRESS_ATTR = 16842872;
    private static final int HORIZONTAL_PROGRESS_STYLE = 16973855;

    private interface Setter {
        void set(Axml xml, Axml.Attribute a);
    }

    /** The layout element [attrs] is, when a compiled layout gave it. */
    private static Axml element(AttributeSet attrs) {
        return attrs instanceof Axml ? (Axml) attrs : null;
    }

    /** [setter] on each android: attribute (and srcCompat), each on its own: one that fails is logged and skipped. */
    private static void each(View view, Axml xml, Setter setter) {
        for (Axml.Attribute a : xml.attributes()) {
            if (!Axml.ANDROID.equals(a.namespace) && !"srcCompat".equals(a.name)) continue;
            try {
                setter.set(xml, a);
            } catch (RuntimeException e) {
                System.err.println("[cs3] layout attribute " + a.name + " on " + view.getClass().getName() + ": " + e);
            }
        }
    }

    /** View's: its id, words for the blind, visibility, enabled and clickable. */
    public static void view(View view, AttributeSet attrs) {
        Axml xml = element(attrs);
        if (xml == null) return;
        xml.made.add(view);
        each(view, xml, (x, a) -> {
            switch (a.name) {
                case "id": if (a.type == Arsc.TYPE_REFERENCE) view.setId(a.data); break;
                case "contentDescription": view.setContentDescription(text(x, a)); break;
                case "visibility": view.setVisibility(visibility(a)); break;
                case "enabled": view.setEnabled(a.data != 0); break;
                case "clickable": view.setClickable(a.data != 0); break;
                default: break;
            }
        });
    }

    /** TextView's: its words, hint, input type, lines, size, style and capitals. */
    public static void text(TextView view, AttributeSet attrs) {
        Axml xml = element(attrs);
        if (xml == null) return;
        each(view, xml, (x, a) -> {
            switch (a.name) {
                case "text": view.setText(text(x, a)); break;
                case "hint": view.setHint(text(x, a)); break;
                case "inputType": view.setInputType(a.data); break;
                case "singleLine": view.setSingleLine(a.data != 0); break;
                case "maxLines": case "lines": view.setMaxLines(a.data); break;
                case "textSize":
                    if (a.type == Arsc.TYPE_DIMENSION) {
                        float px = TypedValue.complexToDimension(a.data, view.getResources().getDisplayMetrics());
                        view.setTextSize(TypedValue.COMPLEX_UNIT_PX, px);
                    }
                    break;
                case "textStyle": view.setTypeface(view.getTypeface(), a.data); break;
                case "textAllCaps": view.setAllCaps(a.data != 0); break;
                default: break;
            }
        });
    }

    /** Material's text field: its hint. */
    public static void hint(TextInputLayout view, AttributeSet attrs) {
        Axml xml = element(attrs);
        if (xml == null) return;
        each(view, xml, (x, a) -> {
            if ("hint".equals(a.name)) view.setHint(text(x, a));
        });
    }

    /** A compound button's: checked. */
    public static void checked(CompoundButton view, AttributeSet attrs) {
        Axml xml = element(attrs);
        if (xml == null) return;
        each(view, xml, (x, a) -> {
            if ("checked".equals(a.name)) view.setChecked(a.data != 0);
        });
    }

    /** A linear layout's: its orientation. */
    public static void orientation(LinearLayout view, AttributeSet attrs) {
        Axml xml = element(attrs);
        if (xml == null) return;
        each(view, xml, (x, a) -> {
            if ("orientation".equals(a.name)) view.setOrientation(a.data);
        });
    }

    /** An image view's: its image (src, or AppCompat's srcCompat). */
    public static void image(ImageView view, AttributeSet attrs) {
        Axml xml = element(attrs);
        if (xml == null) return;
        each(view, xml, (x, a) -> {
            if (("src".equals(a.name) || "srcCompat".equals(a.name)) && a.type == Arsc.TYPE_REFERENCE) view.setImageResource(a.data);
        });
    }

    /** A dropdown's or list's: its items, from a string array. */
    public static void entries(AdapterView<?> view, AttributeSet attrs) {
        Axml xml = element(attrs);
        if (xml == null) return;
        each(view, xml, (x, a) -> {
            if (!"entries".equals(a.name) || a.type != Arsc.TYPE_REFERENCE || x.resources == null) return;
            CharSequence[] items = x.resources.getTextArray(a.data);
            if (view instanceof Spinner) {
                ((Spinner) view).setAdapter(new ArrayAdapter<>(view.getContext(), android.R.layout.simple_spinner_item, items));
            } else if (view instanceof ListView) {
                ((ListView) view).setAdapter(new ArrayAdapter<>(view.getContext(), android.R.layout.simple_list_item_1, items));
            }
        });
    }

    /** A progress bar's, in the order that keeps them: indeterminate first (a bar with a value has none), then the range, then the value. */
    public static void progress(ProgressBar bar, AttributeSet attrs) {
        Axml xml = element(attrs);
        if (xml == null) return;
        Axml.Attribute indeterminate = xml.attribute(Axml.ANDROID, "indeterminate");
        Axml.Attribute style = xml.attribute("", "style");
        if (indeterminate != null) bar.setIndeterminate(indeterminate.data != 0);
        else if (style != null && (style.data == HORIZONTAL_PROGRESS_ATTR || style.data == HORIZONTAL_PROGRESS_STYLE)) bar.setIndeterminate(false);
        Axml.Attribute min = xml.attribute(Axml.ANDROID, "min");
        Axml.Attribute max = xml.attribute(Axml.ANDROID, "max");
        Axml.Attribute progress = xml.attribute(Axml.ANDROID, "progress");
        if (min != null) bar.setMin(min.data);
        if (max != null) bar.setMax(max.data);
        if (progress != null) bar.setProgress(progress.data);
    }

    /** Every class's, for a view no stand-in constructor was given the element: what the inflater sets itself. */
    public static void all(View view, Axml xml) {
        view(view, xml);
        if (view instanceof TextView) text((TextView) view, xml);
        if (view instanceof TextInputLayout) hint((TextInputLayout) view, xml);
        if (view instanceof CompoundButton) checked((CompoundButton) view, xml);
        if (view instanceof LinearLayout) orientation((LinearLayout) view, xml);
        if (view instanceof ImageView) image((ImageView) view, xml);
        if (view instanceof Spinner || view instanceof ListView) entries((AdapterView<?>) view, xml);
        if (view instanceof ProgressBar) progress((ProgressBar) view, xml);
    }

    /** Whether View's constructor was given [xml]'s element for [view]: then its classes set their attributes. */
    public static boolean seen(View view, Axml xml) {
        for (Object made : xml.made) {
            if (made == view) return true;
        }
        return false;
    }

    /** An attribute's words: what it kept, else the string it refers to (the extension's, or Android's common ones). */
    private static CharSequence text(Axml xml, Axml.Attribute a) {
        if (a.raw != null) return a.raw;
        if (a.type == Arsc.TYPE_REFERENCE && xml.resources != null) {
            try {
                return xml.resources.getText(a.data);
            } catch (Resources.NotFoundException e) {
                return null;
            }
        }
        return null;
    }

    /** XML's visible (0), invisible (1) and gone (2) as View's. */
    private static int visibility(Axml.Attribute a) {
        switch (a.data) {
            case 1: return View.INVISIBLE;
            case 2: return View.GONE;
            default: return View.VISIBLE;
        }
    }
}
