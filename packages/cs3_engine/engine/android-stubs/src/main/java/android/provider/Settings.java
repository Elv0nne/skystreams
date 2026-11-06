package android.provider;

import android.content.ContentResolver;
import dev.akash.cs3engine.stubs.FilePreferences;

import java.util.UUID;

public final class Settings {
    public static final class Secure {
        public static final String ANDROID_ID = "android_id";

        /** Only ANDROID_ID is known: a random id kept for this install, like Android's per-app id. */
        public static String getString(ContentResolver resolver, String name) {
            if (!ANDROID_ID.equals(name)) return null;
            android.content.SharedPreferences prefs = FilePreferences.get("cs3_engine_device");
            String id = prefs.getString(ANDROID_ID, null);
            if (id == null) {
                id = UUID.randomUUID().toString().replace("-", "").substring(0, 16);
                prefs.edit().putString(ANDROID_ID, id).apply();
            }
            return id;
        }
    }
}
