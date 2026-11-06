package android.view;

import android.content.Context;
import android.content.res.Resources;
import android.util.AttributeSet;
import android.widget.FrameLayout;
import dev.akash.cs3engine.stubs.Axml;
import dev.akash.cs3engine.stubs.LayoutAttributes;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;
import org.xmlpull.v1.XmlPullParser;

/**
 * Builds stand-in views from an extension's compiled layouts (the spec's "The inflater"): any view class the
 * layout's class loader finds (a framework stand-in, a generated class, the extension's own), include and
 * merge, and the attributes that carry meaning. Sizes, margins, colours and styles are dropped; layout params
 * keep width, height and weight. A class nothing has stands in as an empty view, so the rest still shows.
 */
public class LayoutInflater {
    private static final Set<String> VIEW_PACKAGE = new HashSet<>(Arrays.asList("View", "ViewStub", "SurfaceView", "TextureView"));

    private final Context context;

    protected LayoutInflater(Context context) {
        this.context = context;
    }

    protected LayoutInflater(LayoutInflater original, Context newContext) {
        this.context = newContext;
    }

    public static LayoutInflater from(Context context) { return new LayoutInflater(context); }
    public LayoutInflater cloneInContext(Context newContext) { return new LayoutInflater(newContext); }
    public Context getContext() { return context; }
    public View inflate(int resource, ViewGroup root) { return inflate(resource, root, root != null); }

    /** A layout of the context's resources: the app's, which hold no extension layouts (as on Android). */
    public View inflate(int resource, ViewGroup root, boolean attachToRoot) {
        return inflate(context.getResources().getLayout(resource), root, attachToRoot);
    }

    public View inflate(XmlPullParser parser, ViewGroup root) { return inflate(parser, root, root != null); }

    public View inflate(XmlPullParser parser, ViewGroup root, boolean attachToRoot) {
        if (!(parser instanceof Axml)) throw new InflateException("only compiled layouts inflate here");
        Axml xml = (Axml) parser;
        if (!toStart(xml)) throw new InflateException(xml.getPositionDescription() + ": No start tag found!");
        String name = xml.getName();
        if ("merge".equals(name)) {
            if (root == null || !attachToRoot) throw new InflateException("<merge /> can be used only with a valid ViewGroup root and attachToRoot=true");
            children(xml, root);
            return root;
        }
        View view = create(xml, name);
        ViewGroup.LayoutParams params = root == null ? null : root.generateLayoutParams(xml);
        if (params != null && !attachToRoot) view.setLayoutParams(params);
        descend(xml, view);
        if (root != null && attachToRoot) {
            root.addView(view, params);
            return root;
        }
        return view;
    }

    private static boolean toStart(Axml xml) {
        int type = xml.getEventType();
        while (type != XmlPullParser.START_TAG && type != XmlPullParser.END_DOCUMENT) type = xml.next();
        return type == XmlPullParser.START_TAG;
    }

    /** [view]'s children, or, for a view that isn't a group, past its end tag. */
    private void descend(Axml xml, View view) {
        if (view instanceof ViewGroup) children(xml, (ViewGroup) view);
        else skip(xml);
    }

    private void children(Axml xml, ViewGroup parent) {
        int depth = xml.getDepth();
        for (int type = xml.next(); type != XmlPullParser.END_DOCUMENT; type = xml.next()) {
            if (type == XmlPullParser.END_TAG && xml.getDepth() == depth) return;
            if (type != XmlPullParser.START_TAG) continue;
            String name = xml.getName();
            if ("requestFocus".equals(name) || "tag".equals(name)) {
                skip(xml);
            } else if ("include".equals(name)) {
                include(xml, parent);
            } else if ("merge".equals(name)) {
                throw new InflateException("<merge /> must be the root element");
            } else {
                View child = create(xml, name);
                ViewGroup.LayoutParams params = parent.generateLayoutParams(xml);
                descend(xml, child);
                parent.addView(child, params);
            }
        }
    }

    /** An include: its layout's views where it stands, with its id, visibility, and size when it gives both. */
    private void include(Axml xml, ViewGroup parent) {
        int layout = xml.getAttributeResourceValue("", "layout", 0);
        int id = xml.getAttributeResourceValue(Axml.ANDROID, "id", View.NO_ID);
        int visibility = visibility(xml.attribute(Axml.ANDROID, "visibility"));
        boolean sized = xml.attribute(Axml.ANDROID, "layout_width") != null && xml.attribute(Axml.ANDROID, "layout_height") != null;
        ViewGroup.LayoutParams own = sized ? parent.generateLayoutParams(xml) : null;
        Resources resources = xml.resources;
        skip(xml);
        if (layout == 0 || resources == null) {
            throw new InflateException("You must specify a valid layout reference. The layout ID " + layout + " is not valid.");
        }
        Axml included = (Axml) resources.getLayout(layout);
        if (!toStart(included)) throw new InflateException(included.getPositionDescription() + ": No start tag found!");
        if ("merge".equals(included.getName())) {
            children(included, parent);
            return;
        }
        View view = create(included, included.getName());
        ViewGroup.LayoutParams params = own != null ? own : parent.generateLayoutParams(included);
        descend(included, view);
        if (id != View.NO_ID) view.setId(id);
        if (visibility >= 0) view.setVisibility(visibility);
        parent.addView(view, params);
    }

    private static void skip(Axml xml) {
        int depth = xml.getDepth();
        int type = xml.getEventType();
        while (!(type == XmlPullParser.END_TAG && xml.getDepth() == depth) && type != XmlPullParser.END_DOCUMENT) type = xml.next();
    }

    private View create(Axml xml, String name) {
        String className = "view".equals(name) ? xml.getAttributeValue("", "class") : name;
        if (className == null) className = "View";
        if (className.indexOf('.') < 0) {
            className = VIEW_PACKAGE.contains(className) ? "android.view." + className
                : "WebView".equals(className) ? "android.webkit.WebView" : "android.widget." + className;
        }
        ClassLoader loader = xml.classLoader != null ? xml.classLoader : LayoutInflater.class.getClassLoader();
        xml.made.clear();
        View view;
        try {
            Class<?> type = Class.forName(className, false, loader);
            if (!View.class.isAssignableFrom(type)) throw new ClassCastException(className + " is no view");
            view = construct(type.asSubclass(View.class), xml);
        } catch (ReflectiveOperationException | LinkageError | RuntimeException e) {
            System.err.println("[cs3] layout element " + name + " can't be made here (" + e + "): an empty one stands in");
            boolean group = xml.hasChildElements() || className.endsWith("Layout") || className.endsWith("Group") || className.endsWith("ScrollView");
            view = group ? new FrameLayout(context) : new View(context);
        }
        // Its classes' constructors set the element's attributes, as Android's do; any they weren't given (no
        // (Context, AttributeSet) constructor, a class nothing has) are set now.
        if (!LayoutAttributes.seen(view, xml)) LayoutAttributes.all(view, xml);
        return view;
    }

    private View construct(Class<? extends View> type, AttributeSet attrs) throws ReflectiveOperationException {
        try {
            return type.getConstructor(Context.class, AttributeSet.class).newInstance(context, attrs);
        } catch (NoSuchMethodException e) {
            return type.getConstructor(Context.class).newInstance(context);
        }
    }

    /** XML's visible (0), invisible (1) and gone (2) as View's; -1 when there's none. */
    private static int visibility(Axml.Attribute a) {
        if (a == null) return -1;
        switch (a.data) {
            case 1: return View.INVISIBLE;
            case 2: return View.GONE;
            default: return View.VISIBLE;
        }
    }
}
