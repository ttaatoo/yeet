#!/bin/sh
# Git inspector data-path bench. Builds the yeet test bundle, runs
# GitInspectorBenchTests with the 133-staged / 3-unstaged / 60-commit
# fixture, and writes JSON.
#
# Usage:
#   scripts/bench-git-inspector.sh [out.json]
set -eu
cd "$(dirname "$0")/.."
out=${1:-tmp/git-inspector-bench.json}
mkdir -p "$(dirname "$out")"
case "$out" in
    /*) ;;
    *) out="$PWD/$out" ;;
esac
request=tmp/git-inspector-bench.request
printf '%s\n' "$out" > "$request"
trap 'rm -f "$request"' EXIT
xcodebuild test -project yeet.xcodeproj -scheme yeet \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:yeetTests/GitInspectorBenchTests
if [ ! -f "$out" ]; then
    echo "bench-git-inspector: missing $out" >&2
    exit 1
fi
echo "wrote $out"
