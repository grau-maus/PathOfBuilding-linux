#!/usr/bin/env bash
# Builds the native Linux SimpleGraphic engine and installs it into this repo's runtime/ folder.
#
# Usage: linux/build-simplegraphic.sh [path-to-SimpleGraphic-checkout]
#
# The engine source is the master branch of https://github.com/grau-maus/PathOfBuilding-SimpleGraphic
# (upstream SimpleGraphic plus its Linux port). Defaults to ../PathOfBuilding-SimpleGraphic next to this
# repository, which is cloned if it does not exist yet.
set -euo pipefail

SG_REPO="https://github.com/grau-maus/PathOfBuilding-SimpleGraphic.git"
POB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SG_SRC="${1:-$POB_ROOT/../PathOfBuilding-SimpleGraphic}"

if [[ ! -e "$SG_SRC" ]]; then
	echo "==> Cloning $SG_REPO into $SG_SRC"
	git clone --branch master "$SG_REPO" "$SG_SRC"
fi
SG_SRC="$(cd "$SG_SRC" && pwd)"
BUILD_DIR="${SG_BUILD_DIR:-$SG_SRC/build}"

if [[ ! -f "$SG_SRC/linux/launcher.c" ]]; then
	echo "error: $SG_SRC does not contain the Linux port (linux/launcher.c missing)" >&2
	exit 1
fi

echo "==> Updating submodules"
git -C "$SG_SRC" submodule update --init --recursive

if [[ ! -x "$SG_SRC/vcpkg/vcpkg" ]]; then
	echo "==> Bootstrapping vcpkg"
	"$SG_SRC/vcpkg/bootstrap-vcpkg.sh" -disableMetrics
fi

echo "==> Configuring (first run builds all vcpkg dependencies and takes a while)"
cmake -S "$SG_SRC" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release -DVCPKG_TARGET_TRIPLET=x64-linux

echo "==> Building"
cmake --build "$BUILD_DIR" --parallel "$(nproc)"

echo "==> Installing into $POB_ROOT/runtime"
# Stripped, since these binaries are committed to the repository
cmake --install "$BUILD_DIR" --prefix "$POB_ROOT/runtime" --strip

echo "Done. Start Path of Building with: $POB_ROOT/PathOfBuilding.sh"
