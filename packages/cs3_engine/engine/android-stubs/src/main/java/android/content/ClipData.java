package android.content;

import android.net.Uri;
import android.os.Parcelable;
import java.util.ArrayList;
import java.util.List;

/** A clip: its label and items, each text or a URI. */
public class ClipData implements Parcelable {
    public static class Item {
        private final CharSequence text;
        private final Uri uri;

        public Item(CharSequence text) {
            this.text = text;
            this.uri = null;
        }

        public Item(Uri uri) {
            this.text = null;
            this.uri = uri;
        }

        public CharSequence getText() { return text; }
        public Uri getUri() { return uri; }
        public CharSequence coerceToText(Context context) { return text != null ? text : uri != null ? uri.toString() : ""; }
    }

    private final CharSequence label;
    private final List<Item> items = new ArrayList<>();

    public ClipData(CharSequence label, String[] mimeTypes, Item item) {
        this.label = label;
        items.add(item);
    }

    public static ClipData newPlainText(CharSequence label, CharSequence text) {
        return new ClipData(label, new String[] {"text/plain"}, new Item(text));
    }

    public static ClipData newRawUri(CharSequence label, Uri uri) {
        return new ClipData(label, new String[] {"text/uri-list"}, new Item(uri));
    }

    public CharSequence getLabel() { return label; }
    public void addItem(Item item) { items.add(item); }
    public int getItemCount() { return items.size(); }
    public Item getItemAt(int index) { return items.get(index); }
    @Override public int describeContents() { return 0; }
}
