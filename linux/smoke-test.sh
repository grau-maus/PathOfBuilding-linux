#!/usr/bin/env bash
# Starts a Path of Building AppImage on a private virtual display (Xvfb), lets it load, then checks its log.
# Never touches the real desktop: xvfb-run -a always starts its own, unused display.
#
# Usage: linux/smoke-test.sh path/to/PathOfBuilding-*.AppImage [seconds]
set -euo pipefail

APPIMAGE_FILE="$(readlink -f "${1:?usage: smoke-test.sh APPIMAGE [seconds]}")"
SECONDS_TO_RUN="${2:-45}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
LOG="$WORK/pob.log"

command -v xvfb-run >/dev/null || { echo "error: xvfb-run not found (install the xvfb package)" >&2; exit 1; }

echo "==> Running $(basename "$APPIMAGE_FILE") for ${SECONDS_TO_RUN}s on a virtual display"
# - Sandboxed home, so the test never reads or writes the real user's builds and settings.
# - Extract-and-run avoids needing FUSE (CI runners and containers often lack it).
# - The update check is pointed at a dummy address, so the test never downloads a release.
# - PoB runs in its own process group, which is stopped as a whole, so nothing outlives the test.
mkdir -p "$WORK/home/.local/share"
set +e
HOME="$WORK/home" APPIMAGE_EXTRACT_AND_RUN=1 POB_RELEASE_API="http://127.0.0.1:9/disabled" \
	xvfb-run -a -s "-screen 0 1920x1080x24 -nolisten tcp" bash -c '
		setsid stdbuf -o0 -e0 "$0" > "$1" 2>&1 &
		pid=$!
		for ((i = 0; i < $2; i++)); do
			if ! kill -0 "$pid" 2>/dev/null; then
				wait "$pid"
				echo "exited early with status $?" >> "$1"
				exit 3
			fi
			sleep 1
		done
		kill -TERM -- "-$pid" 2>/dev/null
		sleep 5
		kill -KILL -- "-$pid" 2>/dev/null
		wait "$pid" 2>/dev/null
		exit 0
	' "$APPIMAGE_FILE" "$LOG" "$SECONDS_TO_RUN"
status=$?
set -e

echo "--- PoB log (last 25 lines) ---"
tail -n 25 "$LOG"
echo "-------------------------------"

if [[ $status -ne 0 ]]; then
	echo "FAIL: PoB exited before the test finished (see log above)" >&2
	exit 1
fi
failed=0
for expected in "Renderer initialised" "Loading main script" "Startup time:"; do
	if ! grep -q "$expected" "$LOG"; then
		echo "FAIL: log never reached '$expected'" >&2
		failed=1
	fi
done
if grep -qiE "^Error|Runtime error|stack traceback" "$LOG"; then
	echo "FAIL: errors in log" >&2
	failed=1
fi
[[ $failed -eq 0 ]] && echo "PASS: PoB started, rendered and loaded without errors"
exit $failed
