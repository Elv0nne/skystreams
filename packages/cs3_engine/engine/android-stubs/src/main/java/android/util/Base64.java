package android.util;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/**
 * android.util.Base64 with Android's behaviour: decoding skips any character outside the
 * chosen alphabet and tolerates missing padding; DEFAULT encoding wraps lines at 76
 * characters and ends with a newline.
 */
public class Base64 {
    public static final int DEFAULT = 0;
    public static final int NO_PADDING = 1;
    public static final int NO_WRAP = 2;
    public static final int CRLF = 4;
    public static final int URL_SAFE = 8;
    public static final int NO_CLOSE = 16;

    private Base64() {}

    public static byte[] decode(String str, int flags) {
        return decode(str.getBytes(StandardCharsets.ISO_8859_1), flags);
    }

    public static byte[] decode(byte[] input, int flags) {
        return decode(input, 0, input.length, flags);
    }

    public static byte[] decode(byte[] input, int offset, int len, int flags) {
        boolean urlSafe = (flags & URL_SAFE) != 0;
        char c62 = urlSafe ? '-' : '+';
        char c63 = urlSafe ? '_' : '/';
        StringBuilder sb = new StringBuilder(len);
        for (int i = offset; i < offset + len; i++) {
            char c = (char) (input[i] & 0xff);
            if (c == '=') break;
            if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == c62 || c == c63) {
                sb.append(c);
            }
        }
        switch (sb.length() % 4) {
            case 1: throw new IllegalArgumentException("bad base-64");
            case 2: sb.append("=="); break;
            case 3: sb.append('='); break;
            default: break;
        }
        try {
            java.util.Base64.Decoder decoder = urlSafe ? java.util.Base64.getUrlDecoder() : java.util.Base64.getDecoder();
            return decoder.decode(sb.toString());
        } catch (IllegalArgumentException e) {
            throw new IllegalArgumentException("bad base-64", e);
        }
    }

    public static String encodeToString(byte[] input, int flags) {
        return new String(encode(input, flags), StandardCharsets.US_ASCII);
    }

    public static String encodeToString(byte[] input, int offset, int len, int flags) {
        return new String(encode(input, offset, len, flags), StandardCharsets.US_ASCII);
    }

    public static byte[] encode(byte[] input, int flags) {
        return encode(input, 0, input.length, flags);
    }

    public static byte[] encode(byte[] input, int offset, int len, int flags) {
        java.util.Base64.Encoder encoder = (flags & URL_SAFE) != 0 ? java.util.Base64.getUrlEncoder() : java.util.Base64.getEncoder();
        if ((flags & NO_PADDING) != 0) encoder = encoder.withoutPadding();
        String out = encoder.encodeToString(Arrays.copyOfRange(input, offset, offset + len));
        if ((flags & NO_WRAP) == 0 && !out.isEmpty()) {
            String newline = (flags & CRLF) != 0 ? "\r\n" : "\n";
            StringBuilder sb = new StringBuilder(out.length() + out.length() / 76 * 2 + 2);
            for (int i = 0; i < out.length(); i += 76) {
                sb.append(out, i, Math.min(out.length(), i + 76)).append(newline);
            }
            out = sb.toString();
        }
        return out.getBytes(StandardCharsets.US_ASCII);
    }
}
