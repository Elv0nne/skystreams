package android.webkit;

import android.net.Uri;
import java.util.Map;

/** A request a page makes, as Android describes it to shouldInterceptRequest and shouldOverrideUrlLoading. */
public interface WebResourceRequest {
    Uri getUrl();

    boolean isForMainFrame();

    boolean isRedirect();

    boolean hasGesture();

    String getMethod();

    Map<String, String> getRequestHeaders();
}
