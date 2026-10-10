# Technical notes: how the macOS port works

This is the in-depth companion to the [README](../README.md): what in Infor
Process Designer (IPD) was Windows-specific, how each problem was found and
patched, the gaps that remain, and how to troubleshoot or rebuild.

IPD ships as a Windows-only installer (`IPD_*.jar`), but the application inside
it is a stock **Eclipse RCP 4.33** product and Infor's own code is almost
entirely platform-neutral. Most of the port is packaging. The handful of real
code problems are fixed by small, targeted bytecode patches applied at build
time: string-constant edits, or single call sites redirected to small helper
classes whose source is in `resources/`. Every patch checks that it matched
exactly what it expected, so the build fails loudly if a future Infor release
changes the code underneath it.

## Contents

- [What was actually Windows-specific](#what-was-actually-windows-specific)
- [The code fixes](#the-code-fixes)
- [Install location and macOS privacy (TCC)](#install-location-and-macos-privacy-tcc)
- [Known gaps](#known-gaps)
- [Rebuilding for a future IPD release](#rebuilding-for-a-future-ipd-release)
- [A trap worth knowing about](#a-trap-worth-knowing-about)
- [Troubleshooting](#troubleshooting)
- [Files in this repository](#files-in-this-repository)

## What was actually Windows-specific

Of ~1,800 files in the installer payload, **12** are Windows-only:

| Item | Handling |
|---|---|
| `IPDesigner.exe`, `IPDesigner_console.exe` + their `.ini` | replaced by the `IPDesigner` shell launcher and `IPDesigner.app` |
| `org.eclipse.swt.win32.win32.x86_64` | swapped for `org.eclipse.swt.cocoa.macosx.<arch>` |
| `org.eclipse.equinox.launcher.win32.*` (native launcher fragment) | not needed — we start Equinox through `org.eclipse.equinox.launcher_*.jar` directly |
| `org.eclipse.ui.win32`, `org.eclipse.e4.ui.swt.win32` | dropped (see [Known gaps](#known-gaps)) |
| `org.eclipse.equinox.security.win32` | dropped (see [Known gaps](#known-gaps)) |
| `lib/swt/swt-4.33-win32-x86_64.jar` | replaced with the cocoa build |
| `misc/dll`, `misc/ocx`, `misc/Lawson*.exe` | dropped (see [Known gaps](#known-gaps)) |
| `install/*.pl` (Infor's perl installer, `Win32::Shortcut`, `regsvr32`) | replaced by `build-ipd-macos.sh` |

Infor's Java itself is clean: no registry access, no `cmd.exe`, no `.dll` loading,
no `os.name` branching (`LocalFlowRunner` only *passes* `os.name` through to the
flow environment). The `\com` byte sequences elsewhere in the classes are JVM type
descriptors, not paths.

## The code fixes

### The install-root path

`com.lawson.bpm.designer.frameworkHook` contributes an Equinox
`ExternalJarClassLoadingHook` that puts Infor's runtime jars
(`lib/jar`, `lib/thirdParty`, `lib/jdbc` — ~120 jars listed in `IPDesigner.cfg`)
onto the designer bundle's classpath. It locates the install root like this:

```java
String parent = bundleJar.getAbsoluteFile().getParent();
if (parent.endsWith("\\plugins"))                       // <-- hardcoded
    base = parent.substring(0, parent.length() - "\\plugins".length());
else
    System.out.println(Messages.ExternalJarClassLoadingHook_5 + ": \plugins");
```

On macOS `parent` ends in `/plugins`, the test fails, `base` stays empty, and
**every Infor jar silently falls off the classpath** — the app then dies on the
first Lawson class it touches, with only a stray line on stdout as a clue. This
is the first wall you hit, and the one that keeps IPD from starting at all.

`build-ipd-macos.sh` patches the string constant in place. `"/plugins"` is the
same length as `"\plugins"`, so the constant pool stays byte-for-byte valid — no
recompilation, no decompiler round-trip, and the jar is unsigned so nothing
breaks. The build asserts that the match happened and that the class size is
unchanged; if Infor ever restructures that class, the build fails loudly instead
of producing a broken install.

### Classpath separators


The same hook parses `IPDesigner.cfg`'s jar lists with

```java
new StringTokenizer(value, File.pathSeparator + "\n\r")
```

Infor writes those lists semicolon-separated. On Windows `File.pathSeparator` is
`;`, so that works. On macOS it is `:`, so the semicolons are not delimiters and
the whole 88-entry list comes back as a *single token* — one impossible filename.
The symptom is identical to the `\plugins` bug (Infor's jars silently absent,
`NoClassDefFoundError` on a `com.lawson.*` class) but the cause is separate, and
fixing only the first one gets you all the way to a running framework before it
dies.

`IPDesigner.cfg` is a plain config file, so no second bytecode patch is needed:
the build rewrites the `depends.*` lists to use `:`. The build then emulates that
tokenizer exactly — same delimiter set — and asserts every jar it yields is on
disk, so a regression here fails the build instead of surfacing as a stack trace
at startup.

### Three more in the designer plugin

Found by running it, not by reading it. Each is a string constant in
`com.lawson.bpm.designer`, patched by byte pattern (including the
`CONSTANT_Utf8` tag and length prefix, so a match is unambiguous):

| Where | Windows assumption | Symptom on macOS |
|---|---|---|
| `DesignerPlugin.getDesignerFilePath` | strips a 6-char `"file:/"` prefix from `FileLocator.toFileURL(...).toExternalForm()` | `file:/C:/x` → `C:/x` is right on Windows; `file:/Users/x` → `Users/x` loses the root slash, `bpm.properties` can never be read, and the designer silently falls back to **offline mode** |
| `FileSelectionDialog` | appends `"\"` to the directory | save/open produce `/Users/you/Downloads\/test.lpd` |
| `WorkunitsView` | builds `<dir>\<id>_Workunit<n>.log` | workunit logs unwritable |

The first is the interesting one: shortening the constant to `"file:"` leaves the
prefix test matching while `substring()` keeps the leading slash. Class files
store no absolute offsets, so changing a constant's *length* is safe — only that
entry's own `u2` length field has to agree, which the replacement carries. The
build asserts each pattern matches exactly once and fails otherwise.

### The CloudSuite login path

Cloud logins do **not** happen in the designer's JVM. `IPDAuthenticatorLauncher`
spawns a second one — `java -jar plugins/IPDAuthenticator.jar` — which opens an
SWT browser for the OAuth flow and writes session data back on stdout. Two things
break that on macOS:

- **`IPDAuthenticator.jar`'s manifest `Class-Path` hardcodes the win32 SWT jar**,
  which this port replaces. The child then starts with no SWT at all and dies
  instantly, and the designer reports "Unable to login to the Infor Process
  Server" with an empty Status and Message. The build rewrites that entry to the
  cocoa jar and verifies every `Class-Path` entry resolves.
- **The child is launched as a plain `java -jar` with no VM options**, but SWT on
  macOS needs `-XstartOnFirstThread`. The launcher exports
  `JDK_JAVA_OPTIONS=-XstartOnFirstThread`, which the `java` launcher itself reads
  and the child inherits. `JAVA_TOOL_OPTIONS` does *not* work here — it is parsed
  during VM startup, too late to choose the main thread.

To debug this path, trace logging is enabled by *creating the file it writes to*:

```sh
touch ~/lawson-httpclient-trace.log ~/ipd-authenticator-trace.log
```

Restart IPD and retry the login; both files then fill in.

### CloudSuite SSO: BrowserSWT and WebKit

The first fix that needed real bytecode work rather than a constant edit.
`LawsonHttpClient`'s `BrowserSWT.strDifference()` pulls the session URL out of
the browser's page text like this:

```java
int i = content.indexOf("https");
String sub  = content.substring(i);
int j = sub.indexOf("<");
String tail = sub.substring(j);        // substring(-1) when there is no '<'
url = sub.replace(tail, "");
```

IE and Edge wrap an XML response in an HTML shell, so a `<` is always present
and `tail` is the markup after the URL. WebKit — the only `Browser` engine SWT
has on macOS — hands back the bare URL, so `indexOf` returns -1 and
`substring(-1)` throws `StringIndexOutOfBoundsException`. `handleLogin` catches
everything in one block and reports it as *"Failed to Launch SWT web browser
control ...Login Failed"*, which is thoroughly misleading: the browser launched
fine and the SSO round trip had already **succeeded**. The trace log
(`~/lawson-httpclient-trace.log`) is where the real message —
`Range [-1, 328) out of bounds for length 328` — actually appears.

`BrowserSWT` is far too large to recompile from bytecode, so `patch-browserswt.py`
retargets just the two `String.substring(int)` calls *inside `strDifference`* to
`SafeStr.substring()`, which clamps a negative index to `""`. That makes
`sub.replace("", "")` a no-op and yields the whole URL — identical to what the
Windows path produces. `invokevirtual` and `invokestatic` are both three bytes
and the stack shape is unchanged (`String,int -> String`), so no offsets, code
lengths or stack map frames move; the new constant-pool entries are appended so
existing indices stay valid. The script refuses to run twice and fails if Infor
restructures the method.

Verified by invoking the real patched method under a JVM against three inputs:
a bare URL (throws before the patch, correct after), an HTML-wrapped URL
(**byte-identical before and after** — Windows behaviour is untouched), and the
`amp;`-escaped variant.

Note `WebView2Detect.isWebView2()` also returns *true* on macOS — SWT ignores the
unsupported `SWT.EDGE` style bit rather than throwing — so the trace claims
"IE-Edge brwoser is in use !". It is harmless: cocoa SWT has only WebKit either
way, and the branch changes nothing but that log line.

### Saving .lpd files: the process id

`FgProcess.toXMLString(String)` derives the process id from the file being saved:

```java
if (name.indexOf(".lpd") >= 0)
    name = name.substring(name.lastIndexOf("\\") + 1, name.indexOf(".lpd"));
xml = PFlowUtils.instance().escapeXmlSpecialCharInProcessName(xml, name);
```

`lastIndexOf("\\")` is -1 on macOS, so `+1` is 0 and the id becomes the whole
absolute path. That would merely be untidy, except the splice downstream is:

```java
int i = xml.indexOf("id=\"");
String head = xml.substring(0, i + 4);
int cut = head.length() + name.length();   // assumes the existing id is this long
return head + escapeSpecialCharacter(name) + xml.substring(cut);
```

It skips `name.length()` characters of the *existing* id. On Windows both are the
basename so the lengths agree. Here the name is longer than the id already in the
XML, so the cut lands past the closing quote and eats into the attributes that
follow — truncating `" priority=` to `rity=` and producing a file that is **not
well-formed XML**. The server rejects it with "process definition was not able to
be loaded", which points at the upload rather than at the save that broke it.

Confirmed by transcribing the splice and reproducing a corrupted file's header
byte-for-byte. Note the damage compounds: the over-run length depends on the id
already stored in the file, so a file saved once with a path-shaped id gets cut
at a different offset the next time.

`patch-fgprocess.py` repoints that one `ldc_w` at a fresh `"/"` constant — new
pool entries appended, instruction still 3 bytes, no shared constant mutated.

**Recovering a file already corrupted this way:** only line 2 is damaged. Restore
`id="<process name>" priority="0"` in the `<process>` tag and the rest of the
document — every activity, property and edge — is intact.

### Ctrl+Space, dark mode, and save-file names

Smaller macOS differences, all in the designer plugin:

- **The Ctrl+Space variable popup never opened.** `VariablePopupList$1.keyPressed`
  gates on `e.stateMask == SWT.CTRL && e.character == 32`. Cocoa SWT fills
  `KeyEvent.character` from `NSEvent.characters()` — the *modified* string — so
  with Control held macOS reports Ctrl+Space as NUL (0), never 32. `keyCode` is 32
  for the space bar on every platform, so `patch-variablepopup.py` repoints that
  one `getfield` from `character` to `keyCode`: same 3-byte instruction, both
  push an int, identical behaviour on Windows.
- **Dark mode hid the node names, then the rest of the UI.** `ActivityNodeFigure`
  draws label text with a hardcoded `ColorConstants.black`, and plenty of other
  IPD widgets assume a light background. Rather than chase every hardcoded
  colour, the port pins the app to the light appearance, in three places:
  - `themeid=org.eclipse.e4.ui.css.theme.e4_default` in the workspace
    preferences keeps the Eclipse CSS theme light (fixes the canvas).
  - `NSRequiresAquaSystemAppearance` in the Info.plist — which turned out *not*
    to apply: the `.app` execs `java`, so the main bundle is the JDK and macOS
    never reads our key. Native widgets (tables, labels, dialogs such as the
    JavaScript Expression Builder) still followed the system and went dark.
  - So `Application.start()` now gets its `Display` from
    `MacAppearance.createDisplay()` instead of `PlatformUI.createDisplay()`.
    It creates the display the normal way, then calls SWT's
    `OS.setTheme(false)`, which sets `NSApp.appearance` to Aqua for every
    window, and then re-runs `Display.initColors()`. That second step matters:
    `Display.init()` caches the system colours (widget background, list
    foreground, ...) while the app is still dark, and switching the appearance
    does not refresh them. Without it the native tables go white but labels,
    panels and the canvas keep dark-mode colours — white text on white rows.
    It logs `[MacAppearance] forced light (Aqua) appearance ...` to
    `logs/ipdesigner.log` along with the resulting widget background and list
    foreground colours. Start with `-Dipd.followSystemAppearance=true` to
    skip it.
- **Downloads saved as `name.lpd.lpd`.** Tools → Manage Processes → Download
  (and Save As) open the save panel with the default name `name.lpd` *and* a
  `*.lpd` filter. `NSSavePanel` hides the extension of the allowed type, treats
  the `.lpd` in the name as part of the base name, and appends the type again on
  Save; Windows' dialog de-duplicates this itself. `FileSelectionDialog.
  getSelectionHelper` now calls `MacFileDialogs.setFilterExtensions` (sets the
  filter, then strips a matching extension from the default name — the panel and
  IPD both add it back) and `MacFileDialogs.getFileNames` (collapses a doubled
  filter extension in what the panel returns). Save dialogs on cocoa only; Open
  dialogs pass straight through.

Both are call-site redirects done by `patch-redirect.py` (the same technique
`patch-loginshell.py` uses for the login window below): one `invokevirtual`/`invokestatic` inside one named method
becomes an `invokestatic` of a helper in `resources/` that takes the receiver as
its first argument. Same instruction size and stack shape, so no offsets or stack
map frames move; the script fails unless it rewrote exactly the expected number
of call sites.

### The login window hides behind the main window

`SplashLoginHandler.renderLogin()` centres the login shell on
`Display.getPrimaryMonitor()` and then goes straight to `createUI()` and an event
loop — it never calls `open()`, `setActive()` or `moveAbove()`. On Windows the
shell surfaces regardless; on cocoa it is left *behind* the main IPD window, and
with a second display "primary monitor" is often not the screen IPD is on. The
symptom is a login you can only reach by dragging the main window out of the way.

`patch-loginshell.py` repoints the single `Shell.setLocation(int,int)` call at
`MacLoginShell.setLocation(Shell,int,int)`, which keeps the original placement
and then, once the UI is built (`asyncExec`, so the shell has a real size by
then), re-centres it on the parent window, clamps it to that monitor's client
area, and raises it with `moveAbove`/`setActive`/`forceActive`. Note the original
centred using the *splash image's* bounds (473x446) as a stand-in for the window
size, which is another reason the placement was never quite right.

## Install location and macOS privacy (TCC)

**Not under `~/Documents` or `~/Desktop`.** Those are TCC-protected: launched from
Finder an app gets its own privacy identity, and an unsigned bundle can be denied
its own install tree with no visible error — the app simply flashes and quits.
Running the same install from a terminal works, because it inherits the
terminal's permissions, which makes this look baffling.

`/Applications/IPDesigner` or `~/Applications/IPDesigner` both work. Move the
**whole folder**, not just the `.app` — the app finds its tree relative to itself
(and falls back to the `--built-at` path). The shim now checks it can write to
the install folder before launching and explains this in a dialog if it can't.

Rebuilding over an existing install preserves `bpm.properties` and `workspace/`,
so server connections survive an upgrade.

## Known gaps

Things that work on Windows and do not here. None of them block normal flow
design, and each is fixable if it ever bites:

- **AGS/DME "IOS Builder" buttons in the String Wizard.** `StringWizard` shells
  out to `LawsonIOSUrlBuilder.exe` / `LawsonIOSAPIBuilder.exe`. Infor's own
  install script notes these were superseded by in-Eclipse builders (PFI-1272),
  so the modern equivalents should be unaffected. Build with
  `--keep-windows-bits` to stash the executables under `IPDesigner/windows-only/`
  if you want to run them through Parallels/Wine.
- **No login prompt at startup.** Infor renders the login UI *on the Eclipse
  splash screen* (`SplashLoginHandler extends AbstractSplashHandler`). The splash
  is drawn by Eclipse's native launcher, which this port does not use — it starts
  Equinox through `org.eclipse.equinox.launcher_*.jar` directly — so the handler
  never fires and IPD comes up offline. **Use Tools → Login instead**: it runs the
  same `SplashLoginHandler` through `LoginAction`, and `renderLogin()` builds its
  own shell, so the identical dialog appears with the connection dropdown, Add
  Connection, user/password and Work Offline. Restoring the startup splash means
  shipping the `org.eclipse.equinox.launcher.cocoa.macosx.<arch>` fragment for its
  JNI splash bridge and passing `-showsplash`.
- **macOS application-menu integration.** `org.eclipse.ui.cocoa` (the counterpart
  to the dropped `org.eclipse.ui.win32`) is not bundled, so About/Preferences/Quit
  live in the app's own menus rather than the `IPDesigner` menu. Cosmetic. To fix,
  drop that fragment into `plugins/` and add it to `osgi.bundles`.
- **Equinox secure storage** falls back to a master-password prompt instead of the
  OS keystore, since `org.eclipse.equinox.security.win32` has no replacement here.
  IPD keeps credentials in `bpm.properties`, so this should never surface. The
  fix, if it does, is `org.eclipse.equinox.security.macosx` from the same Eclipse
  4.33 drop.
- **"run cmd.exe (Windows only)"** in the System Command node property page is a
  label describing where the *flow* executes on the server. Nothing to do with
  the designer's host OS.

## Rebuilding for a future IPD release

Infor ships these quarterly. The script derives the SWT bundle id, version and
product version from the payload rather than hardcoding them, so:

```sh
./build-ipd-macos.sh --jar /path/to/IPD_2026.11.xx..NN.jar
```

should just work as long as Infor stays on Eclipse 4.33. If they move to a newer
Eclipse, refresh `vendor/` with the matching SWT build — the version is visible in
`plugins/org.eclipse.swt_*.jar` — by editing the drop URL in `fetch-swt.command`.
Both hard assumptions (the SWT version and the `\plugins` constant) are checked at
build time and fail loudly.

Useful flags: `--dest DIR` (default `./IPDesigner`), `--arch aarch64|x86_64`
(default: this machine), `--keep-windows-bits`, and `--built-at DIR` — the
absolute path the install will actually run from, baked into the launcher so a
relocated `.app` can still find its tree. It defaults to `--dest` and only needs
setting when the build runs somewhere that sees the disk at a different mount
point than the machine that launches it.

## A trap worth knowing about

Equinox scans `plugins/` and treats **everything** in it as a bundle. Leaving a
backup copy of a plugin jar there (`...jar.orig-backup`) gets it loaded as a
second bundle with the same symbolic name; the classpath hook then derives the
install root from the wrong file and silently drops every Infor lib jar. The app
starts, draws an empty window with no menus, and the only clue is a
`ClassNotFoundException` for something like
`com.lawson.bpm.eprocessserver.interfaces.WebInputObject` in the log.

Keep backups outside `plugins/` (and outside `lib/`). The build now fails if it
finds any, or if more than one designer bundle is present.

## Troubleshooting

Launched from Finder there is no console, so the launcher logs to
`IPDesigner/logs/ipdesigner.log`. `eclipse.consoleLog=true` is already set in
`configuration/config.ini`, so OSGi resolution errors land there too.

- **The app opens and immediately closes** — almost always no Java 21 on the
  machine. Note that `/usr/bin/java` exists on stock macOS as a stub that only
  prompts you to install Java, so "java is on my PATH" proves nothing; the
  launcher probes each candidate by actually running it and logs every one it
  found with its version. Install a real JDK 21 (`brew install --cask
  temurin@21`) or set `IPD_JAVA_HOME`.
- **Nothing happens on double-click** — read the log. The launcher logs from its
  first line, so even a pre-JVM failure lands there; JDK and architecture
  problems also raise a dialog.
- **`NoClassDefFoundError` on a `com.lawson.*` class** — the classpath hook fix
  did not take. Confirm with
  `unzip -p IPDesigner/plugins/com.lawson.bpm.designer.frameworkHook_*.jar \
    org/eclipse/osgi/ExternalJarClassLoadingHook.class | grep -c -a -o '/plugins'`
  should print `2`; the same grep for `'\\plugins'` should print `0`.
- **Blank window or SWT crash on launch** — almost always a missing
  `-XstartOnFirstThread`, or an arch mismatch between the JDK and the SWT
  fragment. Both are set by the launcher; check that
  `plugins/org.eclipse.swt.cocoa.macosx.*` matches `java -version`'s architecture.
- **Stale state after a rebuild** — `osgi.clean=true` is set, so the bundle cache
  is rebuilt each start. To reset the workspace instead, delete
  `IPDesigner/workspace`.

## Files in this repository

```
fetch-swt.command      one-time download of macOS SWT from eclipse.org
patch-browserswt.py    retargets the unsafe substring calls in BrowserSWT (SSO fix)
patch-fgprocess.py     fixes the process-id separator used when saving .lpd files
patch-variablepopup.py fixes the Ctrl+Space variable popup key test
patch-loginshell.py    centres and raises the login window
patch-redirect.py      redirects one call site to a helper (dark mode, save names)
build-ipd-macos.sh     the port: unpack -> swap platform bits -> patch -> package
make-icon.py           builds the app icon from the installer's InforIcon48x48.ico
resources/             helper classes (+ .java sources) patched into the designer plugin
docs/                  this file
vendor/                downloaded SWT archives (created by fetch-swt.command; not committed)
IPDesigner/            build output (not committed)
```
