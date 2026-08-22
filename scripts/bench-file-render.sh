#!/bin/sh
# File-editor FPS bench. Builds tools/file-render-bench (same highlighter
# sources as the app) and writes JSON.
#
# Usage:
#   scripts/bench-file-render.sh [out.json]
set -eu
cd "$(dirname "$0")/.."
out=${1:-tmp/file-render-bench.json}
mkdir -p "$(dirname "$out")"
xcodebuild -project tools/file-render-bench/file-render-bench.xcodeproj \
    -scheme file-render-bench -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
    build
bin=$(xcodebuild -project tools/file-render-bench/file-render-bench.xcodeproj \
    -scheme file-render-bench -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
    -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR = / { dir=$2 } /^ *FULL_PRODUCT_NAME = / { name=$2 } END { print dir "/" name }')
exec "$bin" "--bench-out=$out"
