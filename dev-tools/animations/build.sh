#!/usr/bin/env bash
# Compiles the tools into ./.bin (ignored by git)
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .bin
for tool in probe trace levers geom; do
    # Swift 5 mode: these are quick scripts with global mutable state, not worth strict concurrency
    swiftc -O -swift-version 5 -suppress-warnings "$tool.swift" -o ".bin/$tool"
done
echo "Built: $(ls .bin | tr '\n' ' ')"
