#!/usr/bin/env bash
# Ad-hoc Release build of this fork for the in-repo Homebrew tap and
# GitHub Releases. Does not notarize, does not bump MARKETING_VERSION,
# and does not publish to egoist/homebrew-tap or releases.kero.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-"$ROOT/dist"}"
DERIVED="${ROOT}/.derived"
PROJECT="$ROOT/kero.xcodeproj"

# rustup / Homebrew rust are often missing from a stripped PATH.
for candidate in "${HOME}/.cargo/bin" /opt/homebrew/bin /usr/local/bin; do
  if [[ -x "${candidate}/rustc" || -x "${candidate}/xcodebuild" ]]; then
    export PATH="${candidate}:${PATH}"
  fi
done

need() {
  local cmd="$1"
  local hint="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "error: ${cmd} not found. ${hint}" >&2
    exit 1
  fi
}

need xcodebuild "Install Xcode (a version that can open project format 110) and retry."
need rustc "The Alacritty backend needs a Rust toolchain — install it from https://rustup.rs and retry."
need cargo "The Alacritty backend needs a Rust toolchain — install it from https://rustup.rs and retry."
need ditto "ditto is part of macOS."
need codesign "codesign is part of macOS / Xcode."

# MARKETING_VERSION is set on the kero target (Debug and Release match).
# Read it for the log; do not override the project value.
project_setting() {
  local key="$1"
  awk -v key="$key" '
    $1 == key && $2 == "=" {
      val = $3
      sub(/;$/, "", val)
      print val
      exit
    }
  ' "$PROJECT/project.pbxproj"
}

VERSION="$(project_setting MARKETING_VERSION)"
if [[ -z "$VERSION" ]]; then
  echo "error: could not read MARKETING_VERSION from ${PROJECT}/project.pbxproj" >&2
  exit 1
fi

if [[ -d "$ROOT/.git" ]]; then
  git -C "$ROOT" submodule update --init --recursive
fi

# Xcode 27 IDESwiftPackageCore abort-traps when it indexes more
# Package.swift manifests than Package.resolved pins (12 vs 11 on
# Release #3). Only these three Vendor manifests are intentional.
# Fail before xcodebuild if a nested one (e.g. a full Plugin-Neon
# checkout) is present.
extra_manifests="$(find "$ROOT/Vendor" -name Package.swift \
  ! -path "$ROOT/Vendor/STTextView/Package.swift" \
  ! -path "$ROOT/Vendor/STTextView-Plugin-Neon/Package.swift" \
  ! -path "$ROOT/Vendor/TreeSitterTSX/Package.swift")"
if [[ -n "$extra_manifests" ]]; then
  echo "error: extra Package.swift would crash Xcode 27 Resolve Package Graph:" >&2
  echo "$extra_manifests" >&2
  exit 1
fi

mkdir -p "$DEST"

# Native slice only: a universal Release build also needs
# `rustup target add x86_64-apple-darwin` (see CONTRIBUTING.md).
HOST_ARCH="$(uname -m)"

echo "Packaging kero ${VERSION} (Release, ad-hoc, ${HOST_ARCH})…"

xcodebuild \
  -project "$PROJECT" \
  -scheme kero \
  -configuration Release \
  -destination "platform=macOS,arch=${HOST_ARCH}" \
  -derivedDataPath "$DERIVED" \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=NO \
  KERO_SU_FEED_URL="" \
  build

APP="$(find "$DERIVED/Build/Products/Release" -maxdepth 1 -name "Kero.app" -type d | head -n 1)"
if [[ -z "$APP" ]]; then
  echo "error: Kero.app was not produced (Release WRAPPER_NAME is \$(KERO_DISPLAY_NAME).app)" >&2
  exit 1
fi

rm -rf "$DEST/Kero.app"
cp -R "$APP" "$DEST/Kero.app"

# Belt-and-suspenders: never ship the official Sparkle appcast on a
# brew / GitHub Release build of this fork.
PLIST="$DEST/Kero.app/Contents/Info.plist"
if [[ -f "$PLIST" ]]; then
  plutil -replace SUFeedURL -string "" "$PLIST"
  plutil -replace SUEnableAutomaticChecks -bool false "$PLIST"
fi

codesign --force --deep --sign - "$DEST/Kero.app"
ditto -c -k --keepParent "$DEST/Kero.app" "$DEST/Kero.zip"

echo "Built kero ${VERSION}:"
echo "  $DEST/Kero.app"
echo "  $DEST/Kero.zip"
echo
echo "First run on another Mac:"
echo "  xattr -dr com.apple.quarantine \"$DEST/Kero.app\""
echo "  Then open the app (System Settings → Privacy & Security → Open Anyway if Gatekeeper blocks it)."
