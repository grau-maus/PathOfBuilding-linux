#!/usr/bin/env bash
# Builds the Path of Building AppImage from this repository (program files + the committed runtime/ binaries).
#
# Usage: linux/build-appimage.sh RELEASE_TAG [OUTPUT_DIR]
#   RELEASE_TAG  e.g. v2.68.1-linux.1; recorded in the image so its updater can compare it with GitHub releases
#   OUTPUT_DIR   where to write the .AppImage and .sha256 (default: ./dist)
#
# Environment:
#   APPIMAGETOOL  path to an appimagetool binary (default: download the pinned version below)
set -euo pipefail

APPIMAGETOOL_VERSION="1.9.1"
APPIMAGETOOL_SHA256="ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"

POB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:?usage: build-appimage.sh RELEASE_TAG [OUTPUT_DIR]}"
OUT_DIR="$(mkdir -p "${2:-$POB_ROOT/dist}" && cd "${2:-$POB_ROOT/dist}" && pwd)"
OUTPUT="$OUT_DIR/PathOfBuilding-$TAG-x86_64.AppImage"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APPDIR="$WORK/AppDir"
APP="$APPDIR/usr/lib/path-of-building"

echo "==> Staging program into AppDir"
"$POB_ROOT/linux/stage-app.sh" "$APP" master "$TAG"

cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
# Entry point of the Path of Building AppImage.
set -e
HERE="$(dirname "$(readlink -f "$0")")"
APP="$HERE/usr/lib/path-of-building"

# The image is read-only, so the engine gets a writable base folder for its settings (window size and
# position) and log, with the bundled fonts linked into it.
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/path-of-building"
mkdir -p "$STATE/SimpleGraphic"
# PoB creates its "Path of Building" data folder one level deep, so its parent must already exist
mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}"
ln -sfn "$APP/SimpleGraphic/Fonts" "$STATE/SimpleGraphic/Fonts"

# Always override these: after a self-update, the new image is started by the old one and would otherwise
# inherit paths into the old image's mount, which disappears when the old one exits.
export SG_BASE_PATH="$STATE"
export LUA_PATH="$APP/lua/?.lua;$APP/lua/?/init.lua;;"
export LUA_CPATH="$APP/?.so;;"

exec "$APP/PathOfBuilding" "$APP/Launch.lua" "$@"
EOF
chmod +x "$APPDIR/AppRun"

cat > "$APPDIR/path-of-building.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Path of Building
GenericName=Path of Exile Build Planner
Comment=Offline build planner for Path of Exile
Exec=PathOfBuilding %u
Icon=path-of-building
Terminal=false
Categories=Game;Utility;
StartupWMClass=Path of Building
MimeType=x-scheme-handler/pob;
EOF
cp "$POB_ROOT/linux/path-of-building.png" "$APPDIR/path-of-building.png"
ln -s path-of-building.png "$APPDIR/.DirIcon"

if [[ -z "${APPIMAGETOOL:-}" ]]; then
	APPIMAGETOOL="$WORK/appimagetool"
	echo "==> Downloading appimagetool $APPIMAGETOOL_VERSION"
	curl -fsSL -o "$APPIMAGETOOL" \
		"https://github.com/AppImage/appimagetool/releases/download/$APPIMAGETOOL_VERSION/appimagetool-x86_64.AppImage"
	echo "$APPIMAGETOOL_SHA256  $APPIMAGETOOL" | sha256sum -c --quiet
	chmod +x "$APPIMAGETOOL"
fi

echo "==> Building $OUTPUT"
# Extract-and-run lets appimagetool work where FUSE is unavailable (e.g. CI containers)
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 "$APPIMAGETOOL" --no-appstream "$APPDIR" "$OUTPUT"
(cd "$OUT_DIR" && sha256sum "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256")

echo "Done: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
