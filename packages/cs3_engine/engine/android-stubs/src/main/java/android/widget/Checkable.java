package android.widget;

/** Something that can be checked. */
public interface Checkable {
    void setChecked(boolean checked);

    boolean isChecked();

    void toggle();
}
