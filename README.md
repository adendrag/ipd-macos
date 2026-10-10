# Infor Process Designer for macOS

Infor Process Designer (IPD) is only distributed for Windows. This project turns
Infor's official Windows installer into a native macOS install, with an
`IPDesigner.app` you can launch from Finder or the Dock. The build supports both
Apple silicon and Intel Macs.

## How it works

The IPD installer contains a standard Eclipse application, and most of Infor's
code doesn't depend on Windows. The build swaps the Windows-only components
for their macOS equivalents. It then applies a handful of small, checked
patches where Infor's code assumes Windows, such as backslash paths, dialog
behaviour and keyboard handling.
[docs/TECHNICAL.md](docs/TECHNICAL.md) explains each problem, how it was found
and how it's patched.

Only the build scripts and small patches are here. **No Infor software is
included.** You need your own licensed copy of the IPD installer (`IPD_*.jar`),
and the build converts it on your machine.

## What works

- Designing, opening and saving processes (`.lpd` files), offline or connected
- Connecting to servers through **Tools → Login**, including CloudSuite sign-in (SSO)
- Downloading and uploading processes with **Tools → Manage Processes**
- The **Ctrl+Space** variable popup in expression editors
- A consistent light appearance, even when macOS is in Dark Mode

A few Windows-only extras don't work. They're listed under
[Known gaps](docs/TECHNICAL.md#known-gaps).

## Requirements

- macOS on Apple silicon or Intel
- A **Java 21 JDK**, such as [Temurin 21](https://adoptium.net/) or Amazon
  Corretto 21 (`brew install --cask temurin@21`)
- The IPD installer from Infor, for example `IPD_2026.08.03..69.jar`
- `python3` and `perl` (python3 comes with the Xcode Command Line Tools:
  `xcode-select --install`)
- An internet connection for the one-time download of the macOS SWT library
  from eclipse.org (about 9 MB)

## Installation

1. Clone this repository and download the macOS SWT library:

   ```sh
   git clone https://github.com/adendrag/ipd-macos.git
   cd ipd-macos
   ./fetch-swt.command
   ```

2. Build the macOS install from your IPD installer:

   ```sh
   ./build-ipd-macos.sh --jar /path/to/IPD_2026.08.03..69.jar \
                        --dest /Applications/IPDesigner
   ```

   If you leave out `--jar`, the script uses the newest `IPD_*.jar` in this
   folder or the one above it. If you leave out `--dest`, it builds into
   `./IPDesigner`.

3. Open `/Applications/IPDesigner/IPDesigner.app`. Drag it to the Dock to keep
   it there.

**Install outside `~/Documents` and `~/Desktop`.** macOS privacy protection
blocks unsigned apps from reading their own files in those folders, so the app
would flash and quit. `/Applications/IPDesigner` or
`~/Applications/IPDesigner` both work. If you build somewhere else and move it
afterwards, move the **whole folder**, not just the `.app`.

## First run and signing in

IPD starts in offline mode. To connect to a server, choose **Tools → Login**,
add or pick a connection, and sign in. CloudSuite opens its sign-in page in a
browser window.

Connection settings are saved in `bpm.properties` in the install folder, in the
same format as on Windows. To bring over connections from a Windows install,
copy its `login.*` lines into that file.

## Updating

When Infor releases a new IPD version, run the build again with the new
installer and the same `--dest`:

```sh
./build-ipd-macos.sh --jar /path/to/IPD_new.jar --dest /Applications/IPDesigner
```

Your `bpm.properties` and `workspace/` folder are kept, so connections and
settings carry over.

## Troubleshooting

The app writes a log to `logs/ipdesigner.log` in the install folder. Check it
first.

- **The app opens and closes right away.** Java 21 usually isn't installed, or
  the app is in `~/Documents` or `~/Desktop`. The log lists every Java it found.
  To use a specific JDK, set `IPD_JAVA_HOME`.
- **No menus, or an empty window.** A stray file is in the `plugins/` folder,
  such as a backup copy of a plugin. Move it out of `plugins/` and restart.
- **Sign-in fails.** Create `~/lawson-httpclient-trace.log` and
  `~/ipd-authenticator-trace.log` (for example with `touch`), restart, and try
  again. Both files then show the real error. Delete them afterwards, because
  they contain session tokens.

More cases are covered in the
[technical notes](docs/TECHNICAL.md#troubleshooting).

## Disclaimer

This is an independent, unofficial project. It isn't affiliated with,
endorsed by or supported by Infor. Infor, Infor Process Designer, Landmark and
CloudSuite are trademarks of Infor. Use it with software you're licensed to
use, and test processes before relying on them in production.
