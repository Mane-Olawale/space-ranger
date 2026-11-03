#!/bin/sh
# Drop the filesystem/VM caches before a *cold* benchmark run (PLAN.md §2.12 "cold (after purge ... requires admin
# → local only)"). Never run on CI; `purge(8)` needs root and evicts every cached page on the machine.
#
# Usage: sudo Scripts/purge-cache.sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "purge-cache.sh must run as root: sudo $0" >&2
  exit 1
fi
if [ -n "${CI:-}" ]; then
  echo "refusing to purge caches on CI" >&2
  exit 1
fi

sync
/usr/sbin/purge
echo "caches purged at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
