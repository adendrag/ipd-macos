package com.lawson.bpm.designer;

import org.eclipse.swt.graphics.Rectangle;
import org.eclipse.swt.widgets.Monitor;
import org.eclipse.swt.widgets.Shell;

/**
 * macOS port shim for SplashLoginHandler.renderLogin().
 *
 * renderLogin() centres the login shell on Display.getPrimaryMonitor() and never
 * calls open(), setActive() or moveAbove(). On Windows the shell surfaces anyway;
 * on cocoa it is a child window that sits behind the main window, and when the
 * primary monitor is not the display IPD is on it lands on the wrong screen
 * entirely (then tracks the parent, because Cocoa keeps child windows at a fixed
 * offset).
 *
 * Shell does not override Control.getParent(), so the parent shell cannot be
 * relied on here. The main window is found instead as the largest visible shell
 * that is not the login shell.
 */
public final class MacLoginShell {

    private MacLoginShell() { }

    public static void setLocation(final Shell shell, int x, int y) {
        if (shell == null || shell.isDisposed()) return;
        shell.setLocation(x, y);
        try {
            shell.getDisplay().asyncExec(new Runnable() {
                public void run() { place(shell); }
            });
        } catch (Throwable t) {
            System.out.println("[MacLoginShell] could not schedule placement: " + t);
        }
    }

    static void place(Shell shell) {
        if (shell == null || shell.isDisposed()) return;
        try {
            Rectangle b = shell.getBounds();

            Shell main = null;
            long biggest = -1L;
            Shell[] all = shell.getDisplay().getShells();
            for (int i = 0; i < all.length; i++) {
                Shell s = all[i];
                if (s == shell || s.isDisposed() || !s.isVisible()) continue;
                Rectangle r = s.getBounds();
                long a = (long) r.width * (long) r.height;
                if (a > biggest) { biggest = a; main = s; }
            }

            Rectangle area;
            Monitor mon;
            if (main != null) {
                area = main.getBounds();
                mon = main.getMonitor();
            } else {
                mon = shell.getMonitor();
                area = mon.getClientArea();
            }

            int nx = area.x + (area.width - b.width) / 2;
            int ny = area.y + (area.height - b.height) / 2;

            Rectangle ca = mon.getClientArea();
            if (nx + b.width > ca.x + ca.width)   nx = ca.x + ca.width - b.width;
            if (ny + b.height > ca.y + ca.height) ny = ca.y + ca.height - b.height;
            if (nx < ca.x) nx = ca.x;
            if (ny < ca.y) ny = ca.y;

            shell.setLocation(nx, ny);
            if (!shell.isVisible()) shell.setVisible(true);
            shell.moveAbove(null);
            shell.setActive();
            shell.forceActive();

            System.out.println("[MacLoginShell] login=" + b
                    + " main=" + (main == null ? "none" : String.valueOf(area))
                    + " monitorClientArea=" + ca
                    + " -> placed at " + nx + "," + ny);
        } catch (Throwable t) {
            System.out.println("[MacLoginShell] placement failed: " + t);
            t.printStackTrace(System.out);
        }
    }
}
