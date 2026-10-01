#!/usr/bin/env bash
# Launches the real app with generated media and checks it end to end: import, sequence
# creation, Program-monitor playback, undo, and rendering. The app runs its
# SmokeTestDriver (SWUI) when SPLICEWRIGHT_SMOKE_MEDIA/OUTPUT are set, writes
# report.json plus snapshots, and exits.
#
#   scripts/smoke-test.sh [output-dir]      (default: build/smoke)
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-build/smoke}"
app="build/DerivedData/Build/Products/Debug/Splicewright.app"

rm -rf "$out"
mkdir -p "$out/media"
out="$(cd "$out" && pwd)"
swift run --package-path Packages/SplicewrightKit sw-fixtures "$out/media"
[[ -d "$app" ]] || make build

SPLICEWRIGHT_SMOKE_MEDIA="$out/media" SPLICEWRIGHT_SMOKE_OUTPUT="$out" \
  "$app/Contents/MacOS/Splicewright" -ApplePersistenceIgnoreState YES >"$out/app.log" 2>&1 &
pid=$!

screenshot_taken=false
for _ in $(seq 1 240); do
  if [[ -f "$out/snapshot.ready" && $screenshot_taken == false ]]; then
    screencapture -x "$out/screen.png" 2>/dev/null || echo "screencapture unavailable"
    screenshot_taken=true
  fi
  [[ -f "$out/report.json" ]] && ! kill -0 "$pid" 2>/dev/null && break
  kill -0 "$pid" 2>/dev/null || break
  sleep 1
done
kill "$pid" 2>/dev/null || true

echo "--- app log (tail)"
tail -n 40 "$out/app.log" || true
if [[ ! -f "$out/report.json" ]]; then
  echo "Smoke test failed: the app didn't write a report."
  exit 1
fi
echo "--- report"
cat "$out/report.json"

# In CI, print snapshots as base64 so they can be inspected from the job log.
if [[ "${CI:-}" == "true" ]]; then
  for image in window program screen; do
    [[ -f "$out/$image.png" ]] || continue
    sips -s format jpeg -s formatOptions 55 -Z 1400 "$out/$image.png" --out "$out/$image.jpg" >/dev/null
    echo "=== BEGIN $image.jpg"
    base64 -i "$out/$image.jpg" | fold -w 4000
    echo "=== END $image.jpg"
  done
fi

python3 - "$out/report.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
checks = {
    "imported media": r["importedMedia"] >= 4,
    "sequence has clips": r["clipCount"] >= 4,
    "playback advanced": r["playheadAfter"] - r["playheadBefore"] >= 20,
    "program frame rendered": r["programFrameRendered"],
    "undo works": r["undoWorks"],
    "export wrote 30 frames of H.264": r.get("exportSucceeded") and r.get("exportedFrames") == 30
        and r.get("exportedCodec") == "H.264",
    "transition applied": r.get("transitionsApplied", 0) >= 1,
    "title added": r.get("titleAdded"),
    "proxy created": r.get("proxyCreated"),
    "playback with proxies": r.get("proxyPlayback"),
    "export used originals, not proxies": r.get("exportedWidth") == r.get("sequenceWidth") and r.get("sequenceWidth", 0) > 0,
    "cache measured and thumbnails deleted": r.get("cacheBytes", 0) > 0 and r.get("thumbnailCacheCleared"),
    "workspace switched": r.get("workspaceApplied"),
    "keyframes added": r.get("keyframesAdded"),
    "clips copied and pasted": r.get("clipsPasted"),
    "auto-save written": r.get("autoSaveWritten"),
    "log written": r.get("logWritten"),
    "no errors": not r["errors"],
}
for name, ok in checks.items():
    print(("PASS " if ok else "FAIL ") + name)
sys.exit(0 if all(checks.values()) else 1)
PY
