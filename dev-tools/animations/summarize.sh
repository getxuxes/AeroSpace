#!/usr/bin/env bash
# Summarizes a trace output file: how many changed frames have a gap >= 10pt, and the widest gap
set -euo pipefail
awk '/GAPS: [0-9]/ {
    worst = 0
    for (i = 1; i <= NF; i++) if ($i ~ /\(/) { g = $i; gsub(/.*\(|\)/, "", g); if (g + 0 > worst) worst = g + 0 }
    if (worst >= 10) count++
    if (worst > max) max = worst
} END { printf "gapFrames>=10pt=%d worst=%dpt\n", count, max }' "$1"
