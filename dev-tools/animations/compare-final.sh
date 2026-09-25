#!/usr/bin/env bash
# Compares the settled final layout captured by benchmark.sh between two runs (e.g. branch vs main). The whole point of
# the animations is that the FINAL state is identical to main; this fails loudly if any window ends up elsewhere.
#
# Usage: compare-final.sh <labelA> <labelB> [tolerancePt]
set -uo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"
a="$dir/.bin/bench/$1"
b="$dir/.bin/bench/$2"
tol="${3:-1}"
[ -d "$a" ] && [ -d "$b" ] || { echo "Missing run dir: $a or $b"; exit 1; }

fail=0
for fa in "$a"/*.geom; do
  name="$(basename "$fa" .geom)"
  fb="$b/$name.geom"
  [ -f "$fb" ] || { echo "MISSING in $2: $name"; fail=1; continue; }
  diffs=$(awk -v tol="$tol" '
    NR==FNR { x[$1]=$2; y[$1]=$3; w[$1]=$4; h[$1]=$5; next }
    {
      id=$1
      if (!(id in x)) { print "  " id " only in B"; bad=1; next }
      dx=($2-x[id]); dy=($3-y[id]); dw=($4-w[id]); dh=($5-h[id])
      for (k in d) delete d[k]
      if (dx<0)dx=-dx; if (dy<0)dy=-dy; if (dw<0)dw=-dw; if (dh<0)dh=-dh
      if (dx>tol||dy>tol||dw>tol||dh>tol) {
        printf "  %s A=(%d,%d,%d,%d) B=(%d,%d,%d,%d)\n", id, x[id],y[id],w[id],h[id], $2,$3,$4,$5
        bad=1
      }
    }
    END { exit bad?1:0 }
  ' "$fb" "$fa")
  if [ -n "$diffs" ]; then echo "DIFF $name:"; echo "$diffs"; fail=1; else echo "OK   $name"; fi
done
[ "$fail" -eq 0 ] && echo "ALL FINAL STATES IDENTICAL (tol=${tol}pt)" || echo "SOME FINAL STATES DIFFER"
exit "$fail"
