#!/bin/bash
#
# build-ipd-macos.sh -- build a macOS-native install of Infor Process Designer
# from the Windows installer JAR that Infor ships.
#
# Usage:
#   ./build-ipd-macos.sh [--jar FILE] [--dest DIR] [--arch aarch64|x86_64]
#                        [--swt-zip FILE] [--built-at DIR] [--keep-windows-bits]
#
# Defaults: newest IPD_*.jar found next to this script (or one level up),
# this machine's CPU arch, and ./IPDesigner as the destination.
#
# Prerequisites: ./vendor/swt-*-cocoa-macosx-<arch>.zip (run ./fetch-swt.command).
#
set -euo pipefail

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAR=""; DEST=""; ARCH=""; SWTZIP=""; KEEP_WIN=0; BUILT_AT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --jar)       JAR="$2"; shift 2;;
    --dest)      DEST="$2"; shift 2;;
    --arch)      ARCH="$2"; shift 2;;
    --swt-zip)   SWTZIP="$2"; shift 2;;
    --built-at)  BUILT_AT="$2"; shift 2;;
    --keep-windows-bits) KEEP_WIN=1; shift;;
    -h|--help)   sed -n '3,16p' "$0"; exit 0;;
    *) die "unknown option: $1";;
  esac
done

# ---------------------------------------------------------------- inputs ---
[ -n "$JAR" ] || JAR="$(ls -1t "$SCRIPT_DIR"/IPD_*.jar "$SCRIPT_DIR"/../IPD_*.jar 2>/dev/null | head -1 || true)"
[ -n "$JAR" ] && [ -f "$JAR" ] || die "IPD installer jar not found -- pass --jar /path/to/IPD_*.jar"

if [ -z "$ARCH" ]; then
  case "$(uname -m)" in
    arm64|aarch64) ARCH=aarch64;;
    x86_64)        ARCH=x86_64;;
    *) die "unsupported CPU $(uname -m)";;
  esac
fi

[ -n "$SWTZIP" ] || SWTZIP="$(ls -1 "$SCRIPT_DIR"/vendor/swt-*-cocoa-macosx-"$ARCH".zip 2>/dev/null | head -1 || true)"
[ -n "$SWTZIP" ] && [ -f "$SWTZIP" ] || die "no macOS SWT archive for $ARCH in $SCRIPT_DIR/vendor -- run ./fetch-swt.command first"

[ -n "$DEST" ] || DEST="$SCRIPT_DIR/IPDesigner"
case "$DEST" in /*) ;; *) DEST="$PWD/$DEST";; esac
# Absolute path baked into the launcher so a relocated .app can still find the
# tree. Defaults to DEST, but when the build runs somewhere that sees this disk
# at a different mount point, --built-at supplies the path the app will run at.
[ -n "$BUILT_AT" ] || BUILT_AT="$DEST"

for t in unzip zip perl awk sed; do command -v "$t" >/dev/null || die "required tool missing: $t"; done

say "Infor Process Designer -> macOS"
info "installer : $JAR"
info "SWT       : $SWTZIP"
info "arch      : $ARCH"
info "dest      : $DEST"
[ "$BUILT_AT" = "$DEST" ] || info "runs at   : $BUILT_AT"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ------------------------------------------------------------- unpacking ---
say "Unpacking installer payload"
unzip -qo "$JAR" -d "$WORK/payload"
P="$WORK/payload"
[ -d "$P/PFDDIR.ipd.files" ] || die "unexpected installer layout -- is this an IPD package?"

PRODVER="$(awk -F= '/^version=/{print $2}' "$P/PFDDIR.ipd.files/.eclipseproduct" 2>/dev/null | tr -d '\r')"
[ -n "$PRODVER" ] || PRODVER="9.0.0"
info "product version $PRODVER"

# The installer ships platform-neutral payload dirs plus *.Win64 overlays.
# We take only the neutral ones and supply macOS parts ourselves.
# A rebuild must never cost the user their server connections or workspace --
# Infor's own updater preserves these too.
KEEP="$WORK/keep"; mkdir -p "$KEEP"
if [ -f "$DEST/bpm.properties" ]; then
  cp "$DEST/bpm.properties" "$KEEP/bpm.properties"
  say "Preserving existing bpm.properties (server connections)"
fi
if [ -d "$DEST/workspace" ]; then
  cp -R "$DEST/workspace" "$KEEP/workspace"
  info "preserving existing workspace"
fi

say "Assembling install tree"
# Clear the contents rather than the directory itself: DEST can be a mount point
# or otherwise undeletable, and only what is inside it should be replaced.
if [ -d "$DEST" ]; then
  find "$DEST" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  [ -z "$(ls -A "$DEST" 2>/dev/null)" ] || die "could not clear $DEST -- quit IPDesigner if it is running, then retry (nothing was changed)"
else
  mkdir -p "$DEST" || die "could not create $DEST"
fi
cp -R "$P/PFDDIR.ipd.files/." "$DEST/"
cp -R "$P/PFDDIR.ipd.lib.files/lib"        "$DEST/lib"
cp -R "$P/PFDDIR.ipd.plugins.files/plugins" "$DEST/plugins"
[ -d "$P/PFDDIR.ipd.plugins.files/workspace" ] && cp -R "$P/PFDDIR.ipd.plugins.files/workspace" "$DEST/workspace"
[ -d "$P/PFDDIR.ipd.sample.files/samples" ]    && cp -R "$P/PFDDIR.ipd.sample.files/samples"    "$DEST/samples"
mkdir -p "$DEST/workspace" "$DEST/logs"
if [ -f "$KEEP/bpm.properties" ]; then
  cp "$KEEP/bpm.properties" "$DEST/bpm.properties"
  # Belt and braces: if a later build step ever aborts after the tree is laid
  # down but before this point, the connections are still recoverable on disk.
  cp "$KEEP/bpm.properties" "$DEST/bpm.properties.bak"
  info "restored bpm.properties (backup at bpm.properties.bak)"
fi
if [ -d "$KEEP/workspace" ]; then
  rm -rf "$DEST/workspace"; cp -R "$KEEP/workspace" "$DEST/workspace"
  info "restored workspace"
fi

# --------------------------------------------------- strip Windows-only ----
say "Removing Windows-only components"
STASH="$DEST/windows-only"
if [ "$KEEP_WIN" = 1 ]; then mkdir -p "$STASH"; fi
move_out() {
  for f in "$@"; do
    [ -e "$f" ] || continue
    info "drop $(basename "$f")"
    if [ "$KEEP_WIN" = 1 ]; then mv "$f" "$STASH/"; else rm -rf "$f"; fi
  done
}
move_out "$DEST"/plugins/org.eclipse.swt.win32.win32.*.jar \
         "$DEST"/plugins/org.eclipse.ui.win32_*.jar \
         "$DEST"/plugins/org.eclipse.e4.ui.swt.win32_*.jar \
         "$DEST"/plugins/org.eclipse.equinox.security.win32_*.jar \
         "$DEST"/lib/swt/swt-*-win32-*.jar \
         "$DEST"/misc/dll "$DEST"/misc/ocx \
         "$DEST"/misc/LawsonIOSAPIBuilder.exe "$DEST"/misc/LawsonIOSUrlBuilder.exe
rm -f "$DEST"/*.exe "$DEST"/*.ini
# Infor's perl installer is Windows-only and is replaced by this script.
rm -rf "$DEST/install"

# ------------------------------------------------------------ macOS SWT ----
say "Installing macOS SWT"
mkdir -p "$WORK/swt"; unzip -qo "$SWTZIP" -d "$WORK/swt"
SWTJAR="$(find "$WORK/swt" -name 'swt.jar' -maxdepth 3 | head -1)"
[ -n "$SWTJAR" ] || die "swt.jar not found inside $SWTZIP"
unzip -p "$SWTJAR" META-INF/MANIFEST.MF | perl -0777 -pe 's/\r?\n //g' > "$WORK/swt.mf"
SWT_BSN="$(awk -F': ' '/^Bundle-SymbolicName:/{print $2}' "$WORK/swt.mf" | sed 's/;.*//' | tr -d ' \r')"
SWT_VER="$(awk -F': ' '/^Bundle-Version:/{print $2}'      "$WORK/swt.mf" | tr -d ' \r')"
[ -n "$SWT_BSN" ] && [ -n "$SWT_VER" ] || die "could not read SWT bundle id/version from $SWTJAR"
case "$SWT_BSN" in *cocoa.macosx*) ;; *) die "$SWTZIP is not a macOS SWT build ($SWT_BSN)";; esac
cp "$SWTJAR" "$DEST/plugins/${SWT_BSN}_${SWT_VER}.jar"
mkdir -p "$DEST/lib/swt"
SWT_LIB_JAR="$(basename "$SWTZIP" .zip).jar"
cp "$SWTJAR" "$DEST/lib/swt/$SWT_LIB_JAR"
info "$SWT_BSN $SWT_VER"

# --------------------------------------------- rewrite OSGi bundle list ----
say "Rewriting configuration/config.ini for cocoa"
CFG="$DEST/configuration/config.ini"
[ -f "$CFG" ] || die "config.ini missing"
# Fold the backslash-continued osgi.bundles list onto one logical line, then
# swap the win32 fragments for the cocoa one. e4.ui.swt.win32 and ui.win32 have
# no cocoa counterparts in the Eclipse platform and are simply dropped.
awk '{ if (sub(/\\[ \t]*$/, "")) printf "%s", $0; else print }' "$CFG" \
  | sed -e 's/,[ \t]*/,/g' \
        -e "s/org\.eclipse\.swt\.win32\.win32\.[A-Za-z0-9_]*/$SWT_BSN/" \
        -e 's/org\.eclipse\.e4\.ui\.swt\.win32,//' \
        -e 's/,org\.eclipse\.ui\.win32\b//' \
        -e 's/org\.eclipse\.ui\.win32,//' \
        -e 's/,\{2,\}/,/g' -e 's/,$//' > "$CFG.new"
grep -q "$SWT_BSN" "$CFG.new" || die "config.ini rewrite failed: cocoa SWT fragment not listed"
if grep -q 'win32' "$CFG.new"; then die "config.ini rewrite failed: win32 references remain"; fi
mv "$CFG.new" "$CFG"
info "osgi.bundles now lists $SWT_BSN"

# ------------------------------------------ classpath separators -----------
# The same hook parses IPDesigner.cfg's jar lists with
#     new StringTokenizer(value, File.pathSeparator + "\n\r")
# so the delimiters are ";\n\r" on Windows but ":\n\r" here. Infor writes the
# lists semicolon-separated, which on macOS yields ONE token -- the entire list
# as a single absurd filename -- and every Infor jar silently vanishes from the
# classpath. Switch the separators to the platform's own.
say "Converting IPDesigner.cfg jar lists to POSIX path separators"
CFGFILE="$DEST/IPDesigner.cfg"
[ -f "$CFGFILE" ] || die "IPDesigner.cfg missing"
sed -i.bak '/^depends\./ s/;/:/g' "$CFGFILE" && rm -f "$CFGFILE.bak"
grep -q '^depends\.jar=.*:' "$CFGFILE" || die "IPDesigner.cfg separator rewrite failed"
info "depends.jar / depends.thirdParty / depends.jdbc now ':'-separated"

# Emulate the hook's tokenizer exactly and assert every jar it will ask for is
# really on disk. This is the check that would have caught the separator bug.
say "Verifying the jar lists resolve the way the hook parses them"
LISTFILE="$WORK/jarlist.txt"; : > "$LISTFILE"
awk -F= '/^depends\.jar=/        {print "lib/jar|"        $2}
         /^depends\.thirdParty=/ {print "lib/thirdParty|" $2}
         /^depends\.jdbc=/       {print "lib/jdbc|"       $2}' "$CFGFILE" \
| while IFS='|' read -r sub val; do
    printf '%s\n' "$val" | tr ':\r' '\n\n' | while read -r j; do
      [ -n "$j" ] && printf '%s/%s\n' "$sub" "$j" >> "$LISTFILE"
    done
  done
JTOTAL=$(wc -l < "$LISTFILE" | tr -d ' ')
JMISS=0
while read -r rel; do
  [ -f "$DEST/$rel" ] || { JMISS=$((JMISS + 1)); warn "missing $rel"; }
done < "$LISTFILE"
[ "$JTOTAL" -gt 50 ] || die "only $JTOTAL jars parsed out of IPDesigner.cfg -- separator handling is wrong"
[ "$JMISS" -eq 0 ]   || die "$JMISS of $JTOTAL jars named in IPDesigner.cfg are not on disk"
info "$JTOTAL/$JTOTAL jars resolve"

# ------------------------------------- patch Infor's Windows-only hook -----
# com.lawson.bpm.designer.frameworkHook contributes ExternalJarClassLoadingHook,
# which locates the install root as:
#     parent.endsWith("\\plugins") ? parent minus that suffix : <nothing>
# On macOS the parent ends in "/plugins", the test fails, the base path comes
# back empty and every Infor jar under lib/{jar,thirdParty,jdbc} silently falls
# off the classpath -- the app then dies on the first Lawson class it touches.
# The literal is patched in place; "/plugins" is the same length as "\plugins",
# so the class file's constant pool stays byte-for-byte valid.
say "Patching Infor classpath hook for POSIX paths"
HOOK="$(ls -1 "$DEST"/plugins/com.lawson.bpm.designer.frameworkHook_*.jar 2>/dev/null | head -1 || true)"
[ -n "$HOOK" ] || die "frameworkHook plugin not found"
rm -rf "$WORK/hook"; mkdir -p "$WORK/hook"
( cd "$WORK/hook" && unzip -qo "$HOOK" )
CLS="$WORK/hook/org/eclipse/osgi/ExternalJarClassLoadingHook.class"
[ -f "$CLS" ] || die "ExternalJarClassLoadingHook.class not found in $HOOK"
SZ_BEFORE=$(wc -c < "$CLS")
NPATCH=$(perl -e '
  local $/; open(my $i,"<:raw",$ARGV[0]) or die; my $d=<$i>; close $i;
  my $n = ($d =~ s/\\plugins/\/plugins/g);
  open(my $o,">:raw",$ARGV[0]) or die; print $o $d; close $o;
  print $n;' "$CLS")
SZ_AFTER=$(wc -c < "$CLS")
[ "$NPATCH" -ge 1 ] || die "hook patch matched nothing -- Infor may have changed this class"
[ "$SZ_BEFORE" = "$SZ_AFTER" ] || die "hook patch changed class file size ($SZ_BEFORE -> $SZ_AFTER)"
( cd "$WORK/hook" && rm -f "$HOOK" \
    && zip -qX "$HOOK" META-INF/MANIFEST.MF \
    && zip -qXr "$HOOK" . )
info "replaced $NPATCH occurrence(s) of \\plugins in $(basename "$HOOK")"

# --------------------------------------------- IPDAuthenticator ------------
# Cloud (CloudSuite) logins are done by a *separate* JVM: IPDAuthenticatorLauncher
# runs `java -jar plugins/IPDAuthenticator.jar` and reads session data back from
# its stdout. That jar's manifest Class-Path hardcodes the win32 SWT jar, which
# this port replaced -- so the child starts with no SWT, dies immediately, and the
# designer reports "Unable to login" with an empty status and message.
say "Repointing IPDAuthenticator.jar at the macOS SWT jar"
AJAR="$DEST/plugins/IPDAuthenticator.jar"
if [ -f "$AJAR" ]; then
  rm -rf "$WORK/ajar"; mkdir -p "$WORK/ajar"
  ( cd "$WORK/ajar" && unzip -qo "$AJAR" )
  AMF="$WORK/ajar/META-INF/MANIFEST.MF"
  [ -f "$AMF" ] || die "IPDAuthenticator.jar has no manifest"
  perl -e '
    my ($f,$new) = @ARGV;
    local $/; open(my $i,"<:raw",$f) or die; my $m = <$i>; close $i;
    $m =~ s/\r\n/\n/g;
    $m =~ s/\n //g;                                  # unfold continuations
    my $n = ($m =~ s{(?:\.\./lib/swt/)?swt-[^\s]*win32[^\s]*\.jar}{../lib/swt/$new}g);
    die "no win32 swt reference found in manifest\n" unless $n;
    my $out = "";                                    # refold at 72 bytes
    for my $line (split /\n/, $m) {
      if (length($line) <= 72) { $out .= "$line\n"; next; }
      $out .= substr($line, 0, 72) . "\n";
      my $rest = substr($line, 72);
      while (length($rest) > 71) { $out .= " " . substr($rest,0,71) . "\n"; $rest = substr($rest,71); }
      $out .= " $rest\n" if length $rest;
    }
    open(my $o,">:raw",$f) or die; print $o $out; close $o;
    print "rewrote $n reference(s)\n";
  ' "$AMF" "$SWT_LIB_JAR" || die "could not rewrite IPDAuthenticator manifest"
  ( cd "$WORK/ajar" && rm -f "$AJAR" && zip -qX "$AJAR" META-INF/MANIFEST.MF && zip -qXr "$AJAR" . )
  unzip -p "$AJAR" META-INF/MANIFEST.MF | tr -d '\r\n ' | grep -q "$(printf '%s' "$SWT_LIB_JAR" | tr -d ' ')" \
    || die "IPDAuthenticator manifest rewrite did not stick"
  info "Class-Path now uses $SWT_LIB_JAR"
else
  warn "IPDAuthenticator.jar not present -- cloud logins may not work"
fi

# ---------------------------------------- process id / .lpd saves ----------
# FgProcess.toXMLString(String) derives the process id from the file being saved
# with name.substring(name.lastIndexOf("\\") + 1, name.indexOf(".lpd")). On macOS
# lastIndexOf is -1, so the id becomes the absolute path. That alone would only
# be untidy, but PFlowUtils.escapeXmlSpecialCharInProcessName then splices with
# cut = head.length() + name.length(), assuming the id already in the XML is the
# same length -- so a longer name slices through the following attributes,
# truncating `" priority=` and writing a .lpd that is not well-formed XML. The
# server rejects it with "process definition was not able to be loaded".
say "Patching FgProcess process-id derivation (.lpd saves)"
BCJ="$DEST/lib/jar/bpm-commons.jar"
if [ ! -f "$BCJ" ]; then
  warn "bpm-commons.jar not found -- skipping the .lpd save fix"
elif ! command -v python3 >/dev/null 2>&1; then
  warn "python3 not found -- skipping the FgProcess fix; saved .lpd files will be corrupted"
else
  rm -rf "$WORK/bcj"; mkdir -p "$WORK/bcj"
  FGC="com/lawson/bpm/processflow/workFlow/flowGraph/FgProcess.class"
  ( cd "$WORK/bcj" && unzip -qo "$BCJ" "$FGC" )
  [ -f "$WORK/bcj/$FGC" ] || die "FgProcess.class not found inside bpm-commons.jar"
  python3 "$SCRIPT_DIR/patch-fgprocess.py" "$WORK/bcj/$FGC" "$WORK/bcj/$FGC.new" \
    || die "FgProcess patch failed"
  mv "$WORK/bcj/$FGC.new" "$WORK/bcj/$FGC"
  ( cd "$WORK/bcj" && zip -qX "$BCJ" "$FGC" )
  info "process ids now come from the file's basename, not its full path"
fi

# ------------------------------------ BrowserSWT / CloudSuite SSO ----------
# LawsonHttpClient's BrowserSWT.strDifference() finds the end of a URL in the
# browser's text with indexOf("<") and substring()s at that index. IE and Edge
# wrap an XML response in an HTML shell so a '<' is always present; WebKit --
# SWT's only Browser engine on macOS -- returns the bare URL, indexOf gives -1,
# and substring(-1) throws. The exception is swallowed and surfaces as
# "Failed to Launch SWT web browser control ...Login Failed" *after* SSO has
# already succeeded. See patch-browserswt.py for the bytecode details.
say "Patching BrowserSWT for WebKit (CloudSuite SSO)"
LHC="$DEST/lib/thirdParty/lawson-httpclient.jar"
if [ ! -f "$LHC" ]; then
  warn "lawson-httpclient.jar not found -- skipping SSO fix"
elif ! command -v python3 >/dev/null 2>&1; then
  warn "python3 not found -- skipping the BrowserSWT fix; CloudSuite SSO logins will fail"
  warn "(install the Xcode command line tools and re-run to apply it)"
else
  rm -rf "$WORK/lhc"; mkdir -p "$WORK/lhc"
  ( cd "$WORK/lhc" && unzip -qo "$LHC" 'com/lawson/security/authen/httpclient/BrowserSWT.class' )
  BSWT="$WORK/lhc/com/lawson/security/authen/httpclient/BrowserSWT.class"
  [ -f "$BSWT" ] || die "BrowserSWT.class not found inside lawson-httpclient.jar"
  python3 "$SCRIPT_DIR/patch-browserswt.py" "$BSWT" "$BSWT.new" \
    || die "BrowserSWT patch failed"
  mv "$BSWT.new" "$BSWT"
  [ -f "$SCRIPT_DIR/resources/SafeStr.class" ] || die "resources/SafeStr.class missing"
  cp "$SCRIPT_DIR/resources/SafeStr.class" "$WORK/lhc/com/lawson/security/authen/httpclient/SafeStr.class"
  ( cd "$WORK/lhc" && zip -qX "$LHC" \
      com/lawson/security/authen/httpclient/BrowserSWT.class \
      com/lawson/security/authen/httpclient/SafeStr.class )
  unzip -l "$LHC" | grep -q "SafeStr.class" || die "SafeStr.class did not make it into the jar"
  info "strDifference() now clamps instead of throwing on WebKit page text"
fi

# ------------------------------- Infor's Windows path assumptions ----------
# Three more hardcoded-Windows spots in com.lawson.bpm.designer. Each is a string
# constant in the class file's constant pool, patched by byte pattern including
# the CONSTANT_Utf8 tag and length prefix, so a match is unambiguous. Class files
# store no absolute offsets, so changing a constant's length is safe -- only that
# entry's own u2 length field needs to agree, which the replacement carries.
say "Patching Windows path assumptions in the designer plugin"
DJAR="$DEST/plugins/com.lawson.bpm.designer.jar"
[ -f "$DJAR" ] || die "com.lawson.bpm.designer.jar not found"
rm -rf "$WORK/djar"; mkdir -p "$WORK/djar"
( cd "$WORK/djar" && unzip -qo "$DJAR" )

patch_const() {   # <class file> <old hex> <new hex> <description>
  _f="$WORK/djar/$1"
  [ -f "$_f" ] || die "expected class missing from designer jar: $1"
  _n="$(perl -e '
      my ($file,$oldhex,$newhex) = @ARGV;
      my $old = pack("H*",$oldhex); my $new = pack("H*",$newhex);
      local $/; open(my $i,"<:raw",$file) or die "open: $!"; my $d = <$i>; close $i;
      my $n = ($d =~ s/\Q$old\E/$new/g);
      if ($n) { open(my $o,">:raw",$file) or die; print $o $d; close $o; }
      print $n;' "$_f" "$2" "$3")"
  [ "$_n" = "1" ] || die "patch did not apply cleanly to $1 (matched $_n times) -- $4"
  info "$4"
}

# 1. DesignerPlugin.getDesignerFilePath() strips a 6-char "file:/" prefix from
#    FileLocator.toFileURL(...).toExternalForm(). On Windows "file:/C:/x" -> "C:/x"
#    is right; here "file:/Users/x" -> "Users/x" loses the leading slash, so
#    bpm.properties can never be read and the designer falls back to offline mode.
#    Shortening the constant to "file:" makes the prefix test still match while
#    substring() keeps the root slash.
patch_const "com/lawson/bpm/designer/DesignerPlugin.class" \
  01000666696c653a2f 01000566696c653a \
  "getDesignerFilePath: strip \"file:\" not \"file:/\" (fixes offline mode)"

# 2. FileSelectionDialog builds <dir> + "\" before appending the file name,
#    producing paths like /Users/you/Downloads\/test.lpd.
patch_const "com/lawson/bpm/designer/util/FileSelectionDialog.class" \
  010002015c 010002012f \
  "FileSelectionDialog: directory separator (fixes save/open)"

# 3. WorkunitsView builds <dir> + "\" + <id> + "_Workunit" + <n> + ".log".
patch_const "com/lawson/bpm/designer/views/WorkunitsView\$2.class" \
  015c015f576f726b756e6974 012f015f576f726b756e6974 \
  "WorkunitsView: workunit log path separator"

# 4. SplashLoginHandler.renderLogin() centres the login shell on the *primary*
#    monitor and never calls open()/setActive()/moveAbove(). On cocoa it is left
#    behind the main window (and on a second display, on the wrong screen), so
#    the login is unreachable without shoving IPD aside. MacLoginShell re-centres
#    it on the parent window once built, and raises it.
if command -v python3 >/dev/null 2>&1; then
  SLH="$WORK/djar/com/lawson/bpm/designer/SplashLoginHandler.class"
  if [ -f "$SLH" ]; then
    python3 "$SCRIPT_DIR/patch-loginshell.py" "$SLH" "$SLH.new" || die "login shell patch failed"
    mv "$SLH.new" "$SLH"
    for h in MacLoginShell.class 'MacLoginShell$1.class'; do
      [ -f "$SCRIPT_DIR/resources/$h" ] || die "resources/$h missing"
      cp "$SCRIPT_DIR/resources/$h" "$WORK/djar/com/lawson/bpm/designer/$h"
    done
    info "login window centres on the IPD window and raises itself"
  else
    warn "SplashLoginHandler.class not found -- skipping the login-window fix"
  fi
fi

# 5. VariablePopupList$1.keyPressed gates the Ctrl+Space variable popup on
#    e.character == 32. Cocoa SWT fills character from NSEvent.characters(), so
#    with Control held macOS reports Ctrl+Space as NUL and the popup never opens.
#    keyCode is 32 for the space bar on every platform.
if command -v python3 >/dev/null 2>&1; then
  VPL="$WORK/djar/com/lawson/bpm/designer/util/VariablePopupList\$1.class"
  if [ -f "$VPL" ]; then
    python3 "$SCRIPT_DIR/patch-variablepopup.py" "$VPL" "$VPL.new" \
      || die "VariablePopupList patch failed"
    mv "$VPL.new" "$VPL"
    info "Ctrl+Space variable popup: test keyCode, not character"
  else
    warn "VariablePopupList\$1.class not found -- skipping the Ctrl+Space fix"
  fi
else
  warn "python3 not found -- skipping the Ctrl+Space fix"
fi

# 6. Dark mode. The .app execs java, so the main bundle is the JDK and the
#    NSRequiresAquaSystemAppearance key in Info.plist is never read: NSApp follows
#    the system's Dark mode and native tables, labels and dialogs turn dark while
#    IPD keeps drawing dark text on them. Application.start() now gets its Display
#    from MacAppearance.createDisplay(), which forces NSApp to Aqua via
#    OS.setTheme(false). Opt out with -Dipd.followSystemAppearance=true.
# 7. Save dialogs append ".lpd" twice (Tools > Manage Processes > Download, and
#    any other Save As). FileSelectionDialog passes a default name that already
#    ends in ".lpd" plus a "*.lpd" filter; NSSavePanel hides the extension and
#    then appends it again. MacFileDialogs strips the extension from the default
#    name once the filter is set, and collapses a doubled one in what comes back.
if command -v python3 >/dev/null 2>&1; then
  for h in MacAppearance.class MacFileDialogs.class; do
    [ -f "$SCRIPT_DIR/resources/$h" ] || die "resources/$h missing"
  done
  APC="$WORK/djar/com/lawson/bpm/designer/Application.class"
  python3 "$SCRIPT_DIR/patch-redirect.py" "$APC" "$APC.new" \
    start '(Lorg/eclipse/equinox/app/IApplicationContext;)Ljava/lang/Object;' \
    org/eclipse/ui/PlatformUI createDisplay '()Lorg/eclipse/swt/widgets/Display;' \
    com/lawson/bpm/designer/MacAppearance '()Lorg/eclipse/swt/widgets/Display;' 1 \
    || die "Application appearance patch failed"
  mv "$APC.new" "$APC"
  cp "$SCRIPT_DIR/resources/MacAppearance.class" "$WORK/djar/com/lawson/bpm/designer/"
  info "light (Aqua) appearance forced for native widgets"

  FSD="$WORK/djar/com/lawson/bpm/designer/util/FileSelectionDialog.class"
  FSDSIG='(ILjava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)[Ljava/lang/String;'
  python3 "$SCRIPT_DIR/patch-redirect.py" "$FSD" "$FSD.1" getSelectionHelper "$FSDSIG" \
    org/eclipse/swt/widgets/FileDialog setFilterExtensions '([Ljava/lang/String;)V' \
    com/lawson/bpm/designer/MacFileDialogs '(Lorg/eclipse/swt/widgets/FileDialog;[Ljava/lang/String;)V' 1 \
    || die "FileSelectionDialog setFilterExtensions patch failed"
  python3 "$SCRIPT_DIR/patch-redirect.py" "$FSD.1" "$FSD.new" getSelectionHelper "$FSDSIG" \
    org/eclipse/swt/widgets/FileDialog getFileNames '()[Ljava/lang/String;' \
    com/lawson/bpm/designer/MacFileDialogs '(Lorg/eclipse/swt/widgets/FileDialog;)[Ljava/lang/String;' 1 \
    || die "FileSelectionDialog getFileNames patch failed"
  mv "$FSD.new" "$FSD"; rm -f "$FSD.1"
  cp "$SCRIPT_DIR/resources/MacFileDialogs.class" "$WORK/djar/com/lawson/bpm/designer/"
  info "save dialogs no longer double the .lpd extension"
else
  warn "python3 not found -- skipping the dark-mode and save-name fixes"
fi

( cd "$WORK/djar" && rm -f "$DJAR" \
    && zip -qX "$DJAR" META-INF/MANIFEST.MF \
    && zip -qXr "$DJAR" . )
[ -f "$DJAR" ] || die "failed to repack the designer jar"

# ------------------------------------------------- post-install fixups -----
# Both of these are things Infor's install-pfd.pl does on Windows.
say "Unpacking universal intro content"
for z in "$DEST"/plugins/org.eclipse.ui.intro.universal_*/*.zip; do
  [ -f "$z" ] || continue
  ( cd "$(dirname "$z")" && unzip -qo "$(basename "$z")" && rm -f "$(basename "$z")" )
  info "expanded $(basename "$z")"
done

say "Versioning Infor plugin filenames"
STAMP="$(date +%Y.%m.%d.%H%M)"
for base in com.lawson.bpm.designer com.lawson.bpm.eclipseUI com.lawson.bpm.eclipseUtil com.lawson.help.lpd; do
  f="$DEST/plugins/$base.jar"
  [ -f "$f" ] && mv "$f" "$DEST/plugins/${base}_${STAMP}.jar" && info "${base}_${STAMP}.jar"
done

# ----------------------------------------------------------- launcher ------
say "Writing launcher"
cat > "$DEST/IPDesigner" <<'LAUNCHEOF'
#!/bin/bash
# Launches Infor Process Designer on macOS. Replaces IPDesigner.exe + IPDesigner.ini.
#
# Deliberately does NOT use `set -e`. This is a GUI entry point: a stray non-zero
# status must never kill it silently before anything has been written to the log.
PFDDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCH="@ARCH@"
# Where this tree was built. The install is not relocatable on its own -- if the
# .app gets dragged to /Applications, relative resolution lands nowhere.
BUILT_AT="@PFDDIR@"
if [ ! -d "$PFDDIR/plugins" ] && [ -d "$BUILT_AT/plugins" ]; then PFDDIR="$BUILT_AT"; fi
LOG="$PFDDIR/logs/ipdesigner.log"

mkdir -p "$PFDDIR/logs" "$PFDDIR/workspace" 2>/dev/null
# Start logging on line one. Launched from Finder there is no console, and every
# failure worth diagnosing happens before the JVM starts.
if [ -t 1 ]; then exec > >(tee -a "$LOG") 2>&1; else exec >>"$LOG" 2>&1; fi
echo "=== $(date '+%Y-%m-%d %H:%M:%S')  IPDesigner launch (wants Java 21, $ARCH) ==="

fail() {
  echo "ERROR: $*"
  msg="$(printf '%s' "$*" | sed 's/"/\\"/g')"
  osascript -e "display alert \"Infor Process Designer\" message \"$msg\"" >/dev/null 2>&1
  exit 1
}

# ---- find a JDK that actually runs ---------------------------------------
# Stock macOS ships /usr/bin/java as a stub whose only job is to tell you to
# install Java. It is executable and it is on PATH, so "the file exists" proves
# nothing -- a candidate counts only if it really reports a version.
probe() { "$1" -version 2>&1 | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' | head -1; }

CANDS=""
add() { [ -n "$1" ] && [ -x "$1" ] && CANDS="$CANDS
$1"; return 0; }

[ -n "$IPD_JAVA_HOME" ] && add "$IPD_JAVA_HOME/bin/java"
if [ -x /usr/libexec/java_home ]; then
  add "$(/usr/libexec/java_home -v 21 2>/dev/null)/bin/java"
  add "$(/usr/libexec/java_home 2>/dev/null)/bin/java"
fi
for h in /Library/Java/JavaVirtualMachines/*/Contents/Home \
         /opt/homebrew/opt/openjdk*/libexec/openjdk.jdk/Contents/Home \
         /usr/local/opt/openjdk*/libexec/openjdk.jdk/Contents/Home; do
  add "$h/bin/java"
done
add "$(command -v java 2>/dev/null)"

JAVA=""; JV=""
echo "-- java candidates (version / path) --"
OLDIFS="$IFS"; IFS='
'
for c in $CANDS; do
  [ -x "$c" ] || continue
  v="$(probe "$c")"
  echo "   ${v:-unusable}  $c"
  if [ -z "$JAVA" ] && [ -n "$v" ] && [ "$v" -ge 21 ] 2>/dev/null; then JAVA="$c"; JV="$v"; fi
done
IFS="$OLDIFS"

if [ -z "$JAVA" ]; then
  fail "No Java 21 runtime found.

Infor Process Designer requires a Java 21 JDK. Install one, for example:

    brew install --cask temurin@21

or point IPD_JAVA_HOME at an existing Java 21 home. Every candidate that was
checked is listed in the log:

$LOG"
fi
echo "-- using Java $JV at $JAVA"

# ---- architecture has to match the bundled SWT natives -------------------
JARCH="$("$JAVA" -XshowSettings:properties -version 2>&1 | sed -n 's/^ *os\.arch = *//p' | head -1)"
case "$JARCH" in
  aarch64|arm64) JARCH=aarch64;;
  x86_64|amd64)  JARCH=x86_64;;
esac
echo "-- jvm os.arch=${JARCH:-unknown}, bundled SWT=$ARCH"
if [ -n "$JARCH" ] && [ "$JARCH" != "$ARCH" ]; then
  fail "Architecture mismatch.

This install bundles SWT for $ARCH, but the JDK at

    $JAVA

runs as $JARCH. SWT loads native libraries, so the two must agree. Either use a
$ARCH JDK, or rebuild for this JVM:

    ./build-ipd-macos.sh --arch $JARCH"
fi

LAUNCHER="$(ls -1 "$PFDDIR"/plugins/org.eclipse.equinox.launcher_*.jar 2>/dev/null | head -1)"
[ -n "$LAUNCHER" ] || fail "Equinox launcher jar missing from $PFDDIR/plugins -- the install tree looks incomplete. Re-run build-ipd-macos.sh."

# Infor's trace logs land in $HOME; copy any from the previous run into the
# install's logs/ so a failure is diagnosable from one place.
for t in "$HOME/lawson-httpclient-trace.log" "$HOME/ipd-authenticator-trace.log"; do
  [ -s "$t" ] || continue
  cp "$t" "$PFDDIR/logs/$(basename "$t" .log)-$(date '+%Y%m%d-%H%M%S').log" 2>/dev/null \
    && echo "-- captured previous $(basename "$t")"
done

echo "-- launcher $(basename "$LAUNCHER")"
# IPD spawns a second JVM (plugins/IPDAuthenticator.jar) for CloudSuite logins,
# as a plain `java -jar` with no VM options. That child opens an SWT browser, so
# on macOS it needs -XstartOnFirstThread as well. JDK_JAVA_OPTIONS is read by the
# java launcher itself and inherited by the child; JAVA_TOOL_OPTIONS is parsed too
# late in VM startup to move the main thread.
export JDK_JAVA_OPTIONS="-XstartOnFirstThread"
echo "-- starting"
exec "$JAVA" \
  -XstartOnFirstThread \
  -Xdock:name=IPDesigner \
  -Xdock:icon="$PFDDIR/IPDesigner.app/Contents/Resources/IPDesigner.icns" \
  -Xms256m -Xmx1024m \
  -Dcom.lawson.command.base \
  -Dorg.apache.cxf.stax.allowInsecureParser=1 \
  -Djavax.xml.soap.SAAJMetaFactory=com.sun.xml.messaging.saaj.soap.SAAJMetaFactoryImpl \
  -Djavax.xml.soap.MetaFactory=com.sun.xml.messaging.saaj.soap.SAAJMetaFactoryImpl \
  -Djava.security.policy="file:$PFDDIR/pfiRmi.policy" \
  -Dosgi.requiredJavaVersion=21 \
  -jar "$LAUNCHER" \
  -os macosx -ws cocoa -arch "$ARCH" \
  -install "$PFDDIR" \
  -configuration "$PFDDIR/configuration" \
  -data "$PFDDIR/workspace" \
  "$@"

fail "Could not start the JVM at $JAVA (exec failed)."
LAUNCHEOF
sed -i.bak -e "s|@ARCH@|$ARCH|" -e "s|@PFDDIR@|$BUILT_AT|" "$DEST/IPDesigner" && rm -f "$DEST/IPDesigner.bak"
chmod +x "$DEST/IPDesigner"

# ------------------------------------------------------------ app bundle ---
say "Building IPDesigner.app"
APP="$DEST/IPDesigner.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/MacOS/IPDesigner" <<'SHIMEOF'
#!/bin/bash
# Thin shim: the real launcher lives beside the .app in the install directory.
D="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
[ -x "$D/IPDesigner" ] || D="@PFDDIR@"
if [ ! -x "$D/IPDesigner" ]; then
  osascript -e 'display alert "Infor Process Designer" message "The IPDesigner install directory could not be found. IPDesigner.app has to stay inside its install folder -- move the whole folder, not just the app."' >/dev/null 2>&1
  exit 1
fi
# Launched from Finder an app gets its own sandbox identity, and macOS protects
# ~/Documents and ~/Desktop: an unsigned bundle can be denied its own install
# tree with no visible error. Prove we can write before handing off, so a Finder
# launch always leaves either a log line or an explanation.
if ! ( mkdir -p "$D/logs" && : >> "$D/logs/ipdesigner.log" ) 2>/dev/null; then
  osascript -e "display alert \"Infor Process Designer\" message \"macOS is blocking access to the install folder:

$D

This happens with unsigned apps under ~/Documents or ~/Desktop, which are protected. Grant Full Disk Access to IPDesigner, or move the whole IPDesigner folder somewhere unprotected such as ~/Applications.\"" >/dev/null 2>&1
  exit 1
fi
echo "=== $(date '+%Y-%m-%d %H:%M:%S')  launched from IPDesigner.app (cwd=$PWD) ===" >> "$D/logs/ipdesigner.log"
exec "$D/IPDesigner" "$@"
SHIMEOF
sed -i.bak -e "s|@PFDDIR@|$BUILT_AT|" "$APP/Contents/MacOS/IPDesigner" && rm -f "$APP/Contents/MacOS/IPDesigner.bak"
chmod +x "$APP/Contents/MacOS/IPDesigner"
cat > "$APP/Contents/Info.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>IPDesigner</string>
  <key>CFBundleDisplayName</key>       <string>Infor Process Designer</string>
  <key>CFBundleIdentifier</key>        <string>com.lawson.bpm.designer.Designer</string>
  <key>CFBundleExecutable</key>        <string>IPDesigner</string>
  <key>CFBundleIconFile</key>          <string>IPDesigner</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$PRODVER</string>
  <key>CFBundleVersion</key>           <string>$PRODVER</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key>    <string>11.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSRequiresAquaSystemAppearance</key><true/>
</dict>
</plist>
PLISTEOF
# The icon is built from Infor's own .ico in the installer, so no Infor artwork
# needs to live in this repository.
ICO="$P/PFDDIR.ipd.files/InforIcon48x48.ico"
if [ -f "$ICO" ] && command -v python3 >/dev/null 2>&1 \
   && python3 "$SCRIPT_DIR/make-icon.py" "$ICO" "$APP/Contents/Resources/IPDesigner.icns" >/dev/null; then
  info "icon built from the installer's InforIcon48x48.ico"
else
  warn "could not build the app icon -- the app will use the generic icon"
fi

# Files that arrived via a browser download carry com.apple.quarantine, which
# makes Gatekeeper second-guess the bundle. Harmless to run on a clean tree.
if command -v xattr >/dev/null 2>&1; then
  say "Clearing quarantine attributes"
  xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
fi

# ------------------------------------------------------- appearance --------
# Infor draws activity nodes with hardcoded colours (ActivityNodeFigure uses
# ColorConstants.black for label text), so a dark workbench leaves node names
# black-on-dark and invisible. Pin the light theme; the Info.plist above asks
# macOS for the Aqua appearance for the same reason.
say "Pinning the light workbench theme"
THEMEDIR="$DEST/workspace/.metadata/.plugins/org.eclipse.core.runtime/.settings"
mkdir -p "$THEMEDIR"
cat > "$THEMEDIR/org.eclipse.e4.ui.css.swt.theme.prefs" <<'THEMEEOF'
eclipse.preferences.version=1
themeid=org.eclipse.e4.ui.css.theme.e4_default
THEMEEOF
info "themeid=org.eclipse.e4.ui.css.theme.e4_default"

# Equinox scans plugins/ and treats anything there as a bundle, so a stray copy
# of a plugin jar (a backup, say) is loaded as a second bundle with the same
# symbolic name -- and the classpath hook then derives the install root from the
# wrong file, silently dropping every Infor lib jar. Guard against it.
say "Checking plugins/ for stray files"
STRAY="$(find "$DEST/plugins" -maxdepth 1 \( -name '*.orig-backup' -o -name '*.bak' -o -name '*~' \) 2>/dev/null)"
[ -z "$STRAY" ] || die "stray files in plugins/ would be loaded as duplicate bundles:
$STRAY"
NDESIGNER="$(ls -1 "$DEST"/plugins/com.lawson.bpm.designer_*.jar 2>/dev/null | wc -l | tr -d ' ')"
[ "$NDESIGNER" = "1" ] || die "expected exactly one com.lawson.bpm.designer_*.jar in plugins/, found $NDESIGNER"
info "one designer bundle, no stray files"

# ---------------------------------------------------------------- done -----
say "Done"
info "install root : $DEST"
info "launch       : open '$APP'   (or run '$DEST/IPDesigner' in a terminal)"
info "log          : $DEST/logs/ipdesigner.log"
info "connection settings live in $DEST/bpm.properties"
