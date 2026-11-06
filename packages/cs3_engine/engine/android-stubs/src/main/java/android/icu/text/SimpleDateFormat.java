package android.icu.text;

import java.util.Locale;

/** ICU's SimpleDateFormat mapped onto java.text's; plugins use it to format and parse dates. */
public class SimpleDateFormat extends java.text.SimpleDateFormat {
    public SimpleDateFormat() { super(); }
    public SimpleDateFormat(String pattern) { super(pattern); }
    public SimpleDateFormat(String pattern, Locale locale) { super(pattern, locale); }
}
