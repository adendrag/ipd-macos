package com.lawson.security.authen.httpclient;

/**
 * macOS port shim. BrowserSWT.strDifference() locates the end of a URL inside
 * the browser's text with indexOf("<") and then substring()s at that index --
 * which is -1 whenever the page text carries no markup. IE and Edge wrap an XML
 * response in an HTML shell so a '<' is always present; WebKit hands back the
 * bare URL, so the call throws and the SSO handshake is reported as
 * "Failed to Launch SWT web browser control".
 *
 * Clamping a negative index to "" makes the surrounding
 * url = sub.replace(tail, "") a no-op, which yields the whole URL -- exactly
 * what the Windows path produces.
 */
public final class SafeStr {
    private SafeStr() { }

    public static String substring(String s, int beginIndex) {
        if (s == null) return null;
        if (beginIndex < 0 || beginIndex > s.length()) return "";
        return s.substring(beginIndex);
    }
}
