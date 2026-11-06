package android.content.res;

import android.util.AttributeSet;
import org.xmlpull.v1.XmlPullParser;

/** A compiled XML resource, read as a pull parser that is also its current tag's attribute set. */
public interface XmlResourceParser extends XmlPullParser, AttributeSet, AutoCloseable {
    @Override
    String getAttributeNamespace(int index);

    @Override
    void close();
}
