#!/bin/sh
# Phase 0 benchmark driver (PLAN.md §6 Phase 0, T0-BENCH-2M; ADR-014).
#
# Builds reclaim-bench in Release, generates the 200 k-dir / 2 M-file fixture (unless --root points at an
# existing one), runs each strategy in its own process (so peak RSS is attributable) and merges the three
# JSON reports into one baseline file.
#
# Usage: Scripts/bench.sh [--root PATH] [--out docs/benchmarks/phase0.json] [--repeat 3] [--workers N]
#                         [--dirs N --files M] [--keep] [--strategies "filemanager fts bulk"]
# Requires: swift toolchain, jq (ships with macOS 15+ at /usr/bin/jq).
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT_DIR/Packages/ReclaimKit"
FIXTURE="/private/tmp/rcl-fixture"
OUT="$ROOT_DIR/docs/benchmarks/phase0.json"
REPEAT=3
WORKERS=""
DIRS=200000
FILES=2000000
KEEP=0
STRATEGIES="filemanager fts bulk"

while [ $# -gt 0 ]; do
  case "$1" in
    --root) FIXTURE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --repeat) REPEAT="$2"; shift 2 ;;
    --workers) WORKERS="$2"; shift 2 ;;
    --dirs) DIRS="$2"; shift 2 ;;
    --files) FILES="$2"; shift 2 ;;
    --strategies) STRATEGIES="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "jq is required to merge reports" >&2; exit 1; }

echo "Building reclaim-bench (release)..." >&2
swift build --package-path "$PACKAGE" -c release --product reclaim-bench >/dev/null
BIN="$(swift build --package-path "$PACKAGE" -c release --show-bin-path)/reclaim-bench"

TMP="$(mktemp -d /private/tmp/rcl-bench-reports.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

GENERATED=0
if [ ! -d "$FIXTURE" ]; then
  echo "Generating fixture: $DIRS dirs / $FILES files at ${FIXTURE}..." >&2
  "$BIN" fixture --dirs "$DIRS" --files "$FILES" --out "$FIXTURE" --json > "$TMP/fixture.json"
  GENERATED=1
else
  echo "Using existing fixture at $FIXTURE" >&2
  echo 'null' > "$TMP/fixture.json"
fi

for strategy in $STRATEGIES; do
  echo "Walking with $strategy..." >&2
  # shellcheck disable=SC2086
  "$BIN" walk --strategy "$strategy" --root "$FIXTURE" --repeat "$REPEAT" ${WORKERS:+--workers "$WORKERS"} --json \
    > "$TMP/walk-$strategy.json"
done
if echo "$STRATEGIES" | grep -q bulk; then
  echo "Walking with bulk: worker sweep and per-attribute-set variants..." >&2
  for w in 1 2 4 8; do
    "$BIN" walk --strategy bulk --workers "$w" --root "$FIXTURE" --repeat "$REPEAT" --json > "$TMP/walk-bulk-w$w.json"
  done
  "$BIN" walk --strategy bulk --attrs minimal --root "$FIXTURE" --repeat "$REPEAT" --json > "$TMP/walk-bulk-minimal.json"
  "$BIN" walk --strategy bulk --attrs standard --root "$FIXTURE" --repeat "$REPEAT" --json > "$TMP/walk-bulk-standard.json"
fi

mkdir -p "$(dirname "$OUT")"
# shellcheck disable=SC2016
jq -n --slurpfile fixture "$TMP/fixture.json" \
      --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg gitCommit "$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)" \
      --arg swiftVersion "$(swift --version 2>&1 | head -1)" \
      --arg fixtureRoot "$FIXTURE" \
      '[inputs] as $reports | {
         schema: "reclaim-bench/baseline/v1",
         phase: "0",
         test: "T0-BENCH-2M",
         generatedAt: $generatedAt,
         gitCommit: $gitCommit,
         swiftVersion: $swiftVersion,
         fixture: ($fixture[0] // {root: $fixtureRoot, note: "pre-existing fixture"}),
         host: $reports[0].host,
         walks: [$reports[] | .results[] | {strategy, workers, attributeSet, warmupSeconds, median: .median, best: .best, runs: .runs}]
       }' \
      "$TMP"/walk-*.json > "$OUT.tmp"

# Derived ratios on medians (PLAN.md T0-BENCH-2M): "bulk" is the default-worker, full-attribute walk.
# shellcheck disable=SC2016
jq --argjson defaultWorkers "$("$BIN" walk --help | sed -n 's/.*min(active CPUs, 12)). (default: \([0-9]*\)).*/\1/p')" '
  (first(.walks[] | select(.strategy=="bulk" and .attributeSet=="full" and .workers == $defaultWorkers) | .median.wallSeconds)) as $bulk
  | (first(.walks[] | select(.strategy=="fts") | .median.wallSeconds)) as $fts
  | (first(.walks[] | select(.strategy=="filemanager") | .median.wallSeconds)) as $fm
  | . + {
      ratios: {
        bulkWorkers: $defaultWorkers,
        bulkMedianSeconds: $bulk,
        ftsMedianSeconds: $fts,
        fileManagerMedianSeconds: $fm,
        bulkVsFTS: ($fts / $bulk),
        bulkVsFileManager: ($fm / $bulk),
        planThresholds: {bulkVsFTS: 3.0, bulkVsFileManager: 10.0, bulkMaxSeconds: 3.0},
        meetsPlan: {bulkVsFTS: (($fts / $bulk) >= 3.0), bulkVsFileManager: (($fm / $bulk) >= 10.0), bulkMaxSeconds: ($bulk <= 3.0)}
      }
    }' "$OUT.tmp" > "$OUT"
rm -f "$OUT.tmp"

echo "Baseline written to $OUT" >&2
jq '{host: .host.model, load: .host.loadAverage, memoryStatusLevel: .host.memoryStatusLevel, entries: .walks[0].median.entries, ratios}' "$OUT" >&2

if [ "$GENERATED" -eq 1 ] && [ "$KEEP" -eq 0 ]; then
  echo "Removing fixture ${FIXTURE}..." >&2
  "$BIN" fixture --remove --out "$FIXTURE"
fi
