package android.webkit;

/** A load's error, as Android hands it to onReceivedError. */
public abstract class WebResourceError {
    public abstract int getErrorCode();

    public abstract CharSequence getDescription();
}
