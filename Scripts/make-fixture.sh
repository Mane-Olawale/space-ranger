#!/bin/sh
# Generate the Phase 0 benchmark fixture with `reclaim-bench fixture` (PLAN.md §6 Phase 0).
#
# Usage: Scripts/make-fixture.sh [--dirs N] [--files M] [--out PATH] [--bytes-per-file B] [--configuration debug|release]
# Defaults: 200000 dirs, 2000000 files, /private/tmp/rcl-fixture, 0 bytes per file, release build.
#
# Only build tooling runs through this shell script; the tree itself is created with POSIX calls by the
# Swift executable (REQ-ENUM-1 — never shell globbing or string-built commands).
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/Packages/ReclaimKit"
CONFIGURATION=release
ARGS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --configuration) CONFIGURATION="$2"; shift 2 ;;
    --dirs|--files|--out|--bytes-per-file|--workers) ARGS="$ARGS $1 $2"; shift 2 ;;
    --json) ARGS="$ARGS $1"; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

echo "Building reclaim-bench ($CONFIGURATION)..." >&2
swift build --package-path "$PACKAGE" -c "$CONFIGURATION" --product reclaim-bench >/dev/null
BIN="$(swift build --package-path "$PACKAGE" -c "$CONFIGURATION" --show-bin-path)/reclaim-bench"

# shellcheck disable=SC2086
exec "$BIN" fixture $ARGS
