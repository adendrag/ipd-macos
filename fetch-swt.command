#!/bin/bash
# Downloads the macOS SWT binary for Eclipse 4.33 (the one piece of the IPD port
# that must come from Eclipse.org). Safe to re-run.
set -euo pipefail
mkdir -p "$(dirname "$0")/vendor"
cd "$(dirname "$0")/vendor"
BASE="https://archive.eclipse.org/eclipse/downloads/drops4/R-4.33-202409030240"
for A in aarch64 x86_64; do
  F="swt-4.33-cocoa-macosx-$A.zip"
  if [ -s "$F" ]; then echo "already have $F"; continue; fi
  echo "Downloading $F ..."
  curl -fL --retry 3 -o "$F" "$BASE/$F"
done
ls -la
echo
echo "Done. Both SWT archives are in $(pwd). Next: ./build-ipd-macos.sh --jar /path/to/IPD_*.jar"
