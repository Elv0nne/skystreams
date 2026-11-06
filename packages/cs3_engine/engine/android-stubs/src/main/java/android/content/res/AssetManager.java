package android.content.res;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;
import java.util.Enumeration;
import java.util.LinkedHashSet;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/** An extension's assets: the {@code assets/} files of its .cs3. */
public final class AssetManager implements AutoCloseable {
    private final File cs3;

    AssetManager(File cs3) {
        this.cs3 = cs3;
    }

    public InputStream open(String fileName) throws IOException {
        if (cs3 == null) throw new FileNotFoundException(fileName);
        try (ZipFile zip = new ZipFile(cs3)) {
            ZipEntry entry = zip.getEntry("assets/" + fileName);
            if (entry == null) throw new FileNotFoundException(fileName);
            try (InputStream in = zip.getInputStream(entry)) {
                return new ByteArrayInputStream(in.readAllBytes());
            }
        }
    }

    public InputStream open(String fileName, int accessMode) throws IOException {
        return open(fileName);
    }

    /** The files and folders directly in [path] ("" for the top). */
    public String[] list(String path) throws IOException {
        if (cs3 == null) return new String[0];
        String prefix = "assets/" + (path.isEmpty() ? "" : path.endsWith("/") ? path : path + "/");
        Set<String> names = new LinkedHashSet<>();
        try (ZipFile zip = new ZipFile(cs3)) {
            for (Enumeration<? extends ZipEntry> e = zip.entries(); e.hasMoreElements(); ) {
                String name = e.nextElement().getName();
                if (!name.startsWith(prefix) || name.length() == prefix.length()) continue;
                String rest = name.substring(prefix.length());
                int slash = rest.indexOf('/');
                names.add(slash < 0 ? rest : rest.substring(0, slash));
            }
        }
        return names.toArray(new String[0]);
    }

    @Override public void close() {}
}
