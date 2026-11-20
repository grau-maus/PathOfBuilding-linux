#!/usr/bin/env bash
# Assembles a runnable Path of Building program folder (the same flat layout as a Windows install):
# program files from src/, the native Linux engine and data from runtime/, and a manifest.xml stamped for Linux.
# Used by install.sh and build-appimage.sh.
#
# Usage: linux/stage-app.sh DEST [BRANCH] [RELEASE_TAG]
#   BRANCH       branch of the fork the updater follows (default: master)
#   RELEASE_TAG  release this build belongs to (AppImage builds only, e.g. v2.68.1-linux.1)
set -euo pipefail

POB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:?usage: stage-app.sh DEST [BRANCH] [RELEASE_TAG]}"
BRANCH="${2:-master}"
RELEASE_TAG="${3:-}"

if [[ ! -x "$POB_ROOT/runtime/PathOfBuilding" || ! -f "$POB_ROOT/runtime/libSimpleGraphic.so" ]]; then
	echo "error: native engine missing from runtime/. Run $POB_ROOT/linux/build-simplegraphic.sh first." >&2
	exit 1
fi

mkdir -p "$DEST"

# Program files (same exclusions as the [program] part of manifest.cfg)
tar -C "$POB_ROOT/src" -cf - \
	--exclude=./Export --exclude=./Builds --exclude=./Settings.xml --exclude=./luacov.stats.out \
	--exclude=./HeadlessWrapper.lua --exclude=./LaunchInstall.lua --exclude=./_SimpleGraphic.def.lua \
	--exclude='./TreeData/*/*.bin' --exclude=./poe_api_response.json \
	--exclude='./Data/TimelessJewelData/*.bin' \
	. | tar -C "$DEST" -xf -

# Runtime files, minus the Windows binaries and per-machine state
tar -C "$POB_ROOT/runtime" -cf - \
	--exclude='*.dll' --exclude='*.exe' --exclude=./lua/lua-profiler.lua --exclude=./lua/debugger.lua \
	--exclude=./imgui.ini --exclude=./SimpleGraphic/SimpleGraphic.cfg --exclude=./SimpleGraphic/SimpleGraphic.log \
	--exclude=./SimpleGraphic/Screenshots \
	. | tar -C "$DEST" -xf -

cp "$POB_ROOT/changelog.txt" "$POB_ROOT/help.txt" "$POB_ROOT/LICENSE.md" "$DEST/"

# An installed manifest carries platform + branch, which turns off Dev Mode and enables the updater.
# AppImage builds also record their release tag, which the AppImage updater compares against GitHub releases.
release_attr=""
[[ -n "$RELEASE_TAG" ]] && release_attr=" release=\"$RELEASE_TAG\""
sed -E "s|<Version number=\"([^\"]+)\"[^/]*/>|<Version number=\"\\1\" platform=\"linux\" branch=\"$BRANCH\"$release_attr />|" \
	"$POB_ROOT/manifest.xml" > "$DEST/manifest.xml"
grep -q 'platform="linux"' "$DEST/manifest.xml" || { echo "error: could not stamp manifest.xml" >&2; exit 1; }

# Store builds/settings in the user data folder rather than next to the program
touch "$DEST/installed.cfg"
