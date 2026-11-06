package android.view.inputmethod;

import android.text.InputType;

/** A field's editor: its keyboard action. */
public class EditorInfo implements InputType {
    public static final int IME_MASK_ACTION = 0x000000ff;
    public static final int IME_ACTION_UNSPECIFIED = 0x00000000;
    public static final int IME_ACTION_NONE = 0x00000001;
    public static final int IME_ACTION_GO = 0x00000002;
    public static final int IME_ACTION_SEARCH = 0x00000003;
    public static final int IME_ACTION_SEND = 0x00000004;
    public static final int IME_ACTION_NEXT = 0x00000005;
    public static final int IME_ACTION_DONE = 0x00000006;
    public static final int IME_ACTION_PREVIOUS = 0x00000007;
    public static final int IME_FLAG_NO_EXTRACT_UI = 0x10000000;
    public static final int IME_NULL = 0x00000000;

    public int inputType = TYPE_NULL;
    public int imeOptions = IME_NULL;
    public CharSequence hintText;
    public String packageName;
}
