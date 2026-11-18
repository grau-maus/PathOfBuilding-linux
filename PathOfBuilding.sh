#!/usr/bin/env bash
# Runs Path of Building natively on Linux straight from this repository (Dev Mode).
# Build the engine first with: linux/build-simplegraphic.sh
set -euo pipefail

POB_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LAUNCHER="$POB_ROOT/runtime/PathOfBuilding"

if [[ ! -x "$LAUNCHER" ]]; then
	echo "error: native engine not found at $LAUNCHER" >&2
	echo "Build it first with: $POB_ROOT/linux/build-simplegraphic.sh" >&2
	exit 1
fi

exec "$LAUNCHER" "$POB_ROOT/src/Launch.lua" "$@"
