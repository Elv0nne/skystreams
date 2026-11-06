package android.database;

/** Hears an adapter's data change. */
public abstract class DataSetObserver {
    public void onChanged() {}
    public void onInvalidated() {}
}
