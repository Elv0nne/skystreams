package dev.akash.cs3engine.stubs;

/**
 * Where the DEX converter sends an extension's Class.forName calls. A placeholder (see {@link Placeholder})
 * answers as missing, as Android answers for a class it lacks: WatchParty asks for CloudStream's player so,
 * to tell CloudStream from Nuvio.
 */
public final class ClassProbes {
    private ClassProbes() {}

    private static final StackWalker WALKER = StackWalker.getInstance(StackWalker.Option.RETAIN_CLASS_REFERENCE);

    /** Class.forName(name): from the calling class's loader, as Class.forName looks. */
    public static Class<?> forName(String name) throws ClassNotFoundException {
        return forName(name, true, WALKER.getCallerClass().getClassLoader());
    }

    public static Class<?> forName(String name, boolean initialize, ClassLoader loader) throws ClassNotFoundException {
        Class<?> found = Class.forName(name, initialize, loader);
        if (Placeholder.class.isAssignableFrom(found) && found != Placeholder.class) throw new ClassNotFoundException(name);
        return found;
    }
}
