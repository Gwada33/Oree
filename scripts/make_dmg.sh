#!/bin/bash
# Fabrique Oree-<version>.dmg : fenêtre avec image de fond, Orée à glisser vers Applications.
#   ./scripts/make_dmg.sh            (construit Oree.app d'abord s'il n'existe pas)
# Prérequis : pip3 install dmgbuild
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILT="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Oree.app/Contents/Info.plist 2>/dev/null || true)"
[ "$BUILT" = "$VERSION" ] || ./build_app.sh      # pas d'app, ou une app d'une autre version : on reconstruit
command -v dmgbuild >/dev/null || { echo "Installez dmgbuild : pip3 install dmgbuild"; exit 1; }
OUT="Oree-$VERSION.dmg"
rm -f "$OUT"
dmgbuild -s scripts/dmg-settings.py -D app=Oree.app "Orée $VERSION" "$OUT"
echo "==> $OUT ($(du -h "$OUT" | cut -f1))"
