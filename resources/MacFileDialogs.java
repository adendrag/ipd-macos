package com.lawson.bpm.designer;

import org.eclipse.swt.SWT;
import org.eclipse.swt.widgets.FileDialog;

/**
 * macOS port: stop Save dialogs from producing "name.lpd.lpd".
 *
 * FileSelectionDialog hands the save panel a default name that already carries the
 * extension ("MyProcess.lpd") *and* a filter of "*.lpd". NSSavePanel hides the
 * extension of the allowed type and treats the ".lpd" in the name field as part of
 * the base name, so when the user clicks Save it appends the type again. Windows'
 * dialog de-duplicates this itself.
 *
 * FileSelectionDialog.getSelectionHelper() calls these instead of the FileDialog
 * methods:
 *  - setFilterExtensions: after setting the filters, strip a trailing filter
 *    extension from the default name; the panel (and IPD itself) add it back.
 *  - getFileNames: belt and braces -- collapse a doubled filter extension in the
 *    names the panel returns.
 * Only Save dialogs on cocoa are touched; Open dialogs pass straight through.
 */
public final class MacFileDialogs {
    private MacFileDialogs() {}

    private static boolean applies(FileDialog d) {
        return "cocoa".equals(SWT.getPlatform()) && (d.getStyle() & SWT.SAVE) != 0;
    }

    /** "*.lpd" -> ".lpd"; null for wildcards or anything odd. */
    private static String suffix(String filter) {
        if (filter == null) return null;
        filter = filter.trim();
        int semi = filter.indexOf(';');
        if (semi >= 0) filter = filter.substring(0, semi).trim();
        if (!filter.startsWith("*.") || filter.length() < 3) return null;
        String ext = filter.substring(1);
        return (ext.indexOf('*') >= 0 || ext.indexOf('?') >= 0) ? null : ext;
    }

    public static void setFilterExtensions(FileDialog d, String[] extensions) {
        d.setFilterExtensions(extensions);
        if (!applies(d) || extensions == null) return;
        String name = d.getFileName();
        if (name == null) return;
        for (String f : extensions) {
            String ext = suffix(f);
            if (ext != null && name.length() > ext.length()
                    && name.regionMatches(true, name.length() - ext.length(), ext, 0, ext.length())) {
                String base = name.substring(0, name.length() - ext.length());
                d.setFileName(base);
                System.out.println("[MacFileDialogs] default save name '" + name + "' -> '" + base + "'");
                return;
            }
        }
    }

    public static String[] getFileNames(FileDialog d) {
        String[] names = d.getFileNames();
        if (names == null || !applies(d)) return names;
        String[] filters = d.getFilterExtensions();
        if (filters == null) return names;
        for (int i = 0; i < names.length; i++) {
            String n = names[i];
            if (n == null) continue;
            for (String f : filters) {
                String ext = suffix(f);
                if (ext == null) continue;
                String twice = ext + ext;
                boolean changed = false;
                while (n.length() > twice.length()
                        && n.regionMatches(true, n.length() - twice.length(), twice, 0, twice.length())) {
                    n = n.substring(0, n.length() - ext.length());
                    changed = true;
                }
                if (changed) {
                    System.out.println("[MacFileDialogs] save name '" + names[i] + "' -> '" + n + "'");
                    names[i] = n;
                    break;
                }
            }
        }
        return names;
    }
}
