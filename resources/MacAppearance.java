package com.lawson.bpm.designer;

import java.lang.reflect.Method;

import org.eclipse.swt.SWT;
import org.eclipse.swt.graphics.RGB;
import org.eclipse.swt.widgets.Display;
import org.eclipse.ui.PlatformUI;

/**
 * macOS port: keep IPD in the light (Aqua) appearance.
 *
 * IPD's colours, icons and canvas are drawn for a light background. The app is
 * started by a shell script that execs java, so the main bundle is the JDK and the
 * NSRequiresAquaSystemAppearance key in IPDesigner.app is never consulted; NSApp
 * therefore follows the system's Dark mode.
 *
 * Application.start() calls this instead of PlatformUI.createDisplay(). Two things
 * are needed, in this order, before the workbench creates any widget:
 *  1. switch NSApp to Aqua: OS.setTheme(false) -> Display.setAppAppearance(Light)
 *     -> [NSApp setAppearance:NSAppearanceNameAqua];
 *  2. re-read SWT's system colours. Display.init() caches COLOR_WIDGET_BACKGROUND,
 *     COLOR_LIST_FOREGROUND etc. while the app is still dark, and setAppAppearance
 *     does not refresh them -- so without this, native tables go white but every
 *     label, panel and canvas keeps dark-mode colours (white text on white rows,
 *     dark panels). NSAppearance.currentAppearance is set to Aqua too, so the
 *     dynamic NSColors resolve to their light values.
 *
 * Opt out with -Dipd.followSystemAppearance=true.
 */
public final class MacAppearance {
    private MacAppearance() {}

    public static Display createDisplay() {
        Display display = PlatformUI.createDisplay();
        if (!"cocoa".equals(SWT.getPlatform()) || Boolean.getBoolean("ipd.followSystemAppearance")) {
            return display;
        }
        forceLight(display, "createDisplay");
        // Re-assert once the event loop is running, in case anything flipped it back.
        display.asyncExec(() -> forceLight(display, "workbench started"));
        return display;
    }

    private static void forceLight(Display display, String when) {
        try {
            ClassLoader cl = Display.class.getClassLoader();
            Class<?> os = Class.forName("org.eclipse.swt.internal.cocoa.OS", true, cl);
            os.getMethod("setTheme", boolean.class).invoke(null, Boolean.FALSE);

            // [NSAppearance setCurrentAppearance:[NSAppearance appearanceNamed:NSAppearanceNameAqua]]
            Class<?> nsString = Class.forName("org.eclipse.swt.internal.cocoa.NSString", true, cl);
            Class<?> nsAppearance = Class.forName("org.eclipse.swt.internal.cocoa.NSAppearance", true, cl);
            Object name = nsString.getMethod("stringWith", String.class).invoke(null, "NSAppearanceNameAqua");
            Object aqua = nsAppearance.getMethod("appearanceNamed", nsString).invoke(null, name);
            if (aqua != null) {
                long aquaId = aqua.getClass().getField("id").getLong(aqua);
                long cls = (Long) os.getMethod("objc_getClass", String.class).invoke(null, "NSAppearance");
                long sel = (Long) os.getMethod("sel_registerName", String.class).invoke(null, "setCurrentAppearance:");
                os.getMethod("objc_msgSend", long.class, long.class, long.class).invoke(null, cls, sel, aquaId);
            }

            Method initColors = Display.class.getDeclaredMethod("initColors");
            initColors.setAccessible(true);
            initColors.invoke(display);

            RGB bg = display.getSystemColor(SWT.COLOR_WIDGET_BACKGROUND).getRGB();
            RGB fg = display.getSystemColor(SWT.COLOR_LIST_FOREGROUND).getRGB();
            System.out.println("[MacAppearance] forced light (Aqua) appearance at " + when
                    + "; widget background=" + bg + " list foreground=" + fg);
        } catch (Throwable t) {
            System.out.println("[MacAppearance] could not force light appearance at " + when + ": " + t);
        }
    }
}
