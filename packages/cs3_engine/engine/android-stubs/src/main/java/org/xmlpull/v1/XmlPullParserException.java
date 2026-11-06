package org.xmlpull.v1;

/** XmlPull's checked parse error (public domain API). */
public class XmlPullParserException extends Exception {
    protected Throwable detail;
    protected int row = -1;
    protected int column = -1;

    public XmlPullParserException(String s) {
        super(s);
    }

    public XmlPullParserException(String s, Throwable thrwble) {
        super(s, thrwble);
        this.detail = thrwble;
    }

    public XmlPullParserException(String s, int row, int column) {
        super(s);
        this.row = row;
        this.column = column;
    }

    public XmlPullParserException(String msg, XmlPullParser parser, Throwable chain) {
        super((msg == null ? "" : msg + " ") + (parser == null ? "" : "(position:" + parser.getPositionDescription() + ") ")
            + (chain == null ? "" : "caused by: " + chain), chain);
        if (parser != null) {
            this.row = parser.getLineNumber();
            this.column = parser.getColumnNumber();
        }
        this.detail = chain;
    }

    public Throwable getDetail() { return detail; }
    public int getLineNumber() { return row; }
    public int getColumnNumber() { return column; }
}
