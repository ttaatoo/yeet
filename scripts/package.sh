#!/usr/bin/env bash
# Ad-hoc Release build of this fork for the in-repo Homebrew tap and
# GitHub Releases. Does not notarize, does not bump MARKETING_VERSION,
# and does not publish to egoist/homebrew-tap or releases.kero.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-"$ROOT/dist"}"
DERIVED="${ROOT}/.derived"
PROJECT="$ROOT/yeet.xcodeproj"

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

need xcodebuild "Install Xcode 26.5 or later and retry."
need rustc "The Alacritty backend needs a Rust toolchain — install it from https://rustup.rs and retry."
need cargo "The Alacritty backend needs a Rust toolchain — install it from https://rustup.rs and retry."
need ditto "ditto is part of macOS."
need codesign "codesign is part of macOS / Xcode."

# MARKETING_VERSION is set on the yeet target (Debug and Release match).
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
# Release #3). Only these five Vendor manifests are intentional. Neon and
# STTextKitPlus are local Swift 6 compatibility patches used by the two
# existing wrapper packages.
# Fail before xcodebuild if a nested one (e.g. a full Plugin-Neon
# checkout) is present.
extra_manifests="$(find "$ROOT/Vendor" -name Package.swift \
  ! -path "$ROOT/Vendor/Neon/Package.swift" \
  ! -path "$ROOT/Vendor/STTextView/Package.swift" \
  ! -path "$ROOT/Vendor/STTextView-Plugin-Neon/Package.swift" \
  ! -path "$ROOT/Vendor/STTextKitPlus/Package.swift" \
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

# Share one SourcePackages tree between resolve and build. Xcode 27.0
# beta 4 (27A5228h) on GitHub's xcode-27 runner fetches remotes, then
# abort-traps in IDESwiftPackageCore while registering dependency file
# refs (NSMutableArray 12 vs 11) — Release #4, after the nested
# Plugin-Neon Package.swift was already gone:
# https://github.com/ttaatoo/yeet/actions/runs/32492042501
# Hypothesis: checkouts are already on disk after that abort, so a
# second xcodebuild can compile with automatic resolution disabled.
CLONED_PACKAGES="${DERIVED}/SourcePackages"
mkdir -p "$DERIVED" "$CLONED_PACKAGES"

# True when resolve left usable clones (checkouts and/or repositories).
cloned_packages_populated() {
  local root="$1"
  local path f
  for path in "$root/checkouts" "$root/repositories"; do
    [[ -d "$path" ]] || continue
    for f in "$path"/*; do
      if [[ -e "$f" ]]; then
        return 0
      fi
    done
  done
  return 1
}

echo "Packaging yeet ${VERSION} (Release, ad-hoc, ${HOST_ARCH})…"
echo "Resolving Swift packages into ${CLONED_PACKAGES}…"

# Isolate from set -e: resolve may SIGABRT (exit 134) after a successful
# fetch. This step is mandatory — skipping it on a clean machine would
# build with no packages.
set +e
xcodebuild \
  -project "$PROJECT" \
  -scheme yeet \
  -derivedDataPath "$DERIVED" \
  -clonedSourcePackagesDirPath "$CLONED_PACKAGES" \
  -resolvePackageDependencies
resolve_status=$?
set -euo pipefail

if [[ "$resolve_status" -eq 0 ]]; then
  echo "Package resolve finished (exit 0)."
else
  echo "warning: xcodebuild -resolvePackageDependencies exited ${resolve_status}." >&2
  echo "Xcode 27 may abort in IDESwiftPackageCore after fetch; continuing if clones are on disk." >&2
fi

echo "Cloned package entries:"
if [[ -d "$CLONED_PACKAGES/checkouts" ]]; then
  echo "  checkouts:"
  ls -1 "$CLONED_PACKAGES/checkouts" | sed 's/^/    /' || true
fi
if [[ -d "$CLONED_PACKAGES/repositories" ]]; then
  echo "  repositories:"
  ls -1 "$CLONED_PACKAGES/repositories" | sed 's/^/    /' || true
fi

if ! cloned_packages_populated "$CLONED_PACKAGES"; then
  echo "error: ${CLONED_PACKAGES} has no checkouts/ or repositories/ after resolve (exit ${resolve_status})." >&2
  echo "The checkouts-survive-abort hypothesis does not hold for this run; cannot build with empty packages." >&2
  if [[ -d "$CLONED_PACKAGES" ]]; then
    echo "Contents of ${CLONED_PACKAGES}:" >&2
    find "$CLONED_PACKAGES" -maxdepth 2 >&2 || true
  fi
  exit 1
fi

echo "Building with automatic package resolution disabled…"

# Xcode 26.5 turns coverage on for scheme builds even when the test plan
# does not ask for it. An instrumented `yeet` then writes default.profraw
# into every project directory when `yeet +agent _integration` exits.
xcodebuild \
  -project "$PROJECT" \
  -scheme yeet \
  -configuration Release \
  -destination "platform=macOS,arch=${HOST_ARCH}" \
  -derivedDataPath "$DERIVED" \
  -clonedSourcePackagesDirPath "$CLONED_PACKAGES" \
  -disableAutomaticPackageResolution \
  -skipPackageUpdates \
  -onlyUsePackageVersionsFromResolvedFile \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=NO \
  CLANG_COVERAGE_MAPPING=NO \
  CLANG_ENABLE_CODE_COVERAGE=NO \
  ENABLE_CODE_COVERAGE=NO \
  KERO_SU_FEED_URL="" \
  build

APP="$(find "$DERIVED/Build/Products/Release" -maxdepth 1 -name "Yeet.app" -type d | head -n 1)"
if [[ -z "$APP" ]]; then
  echo "error: Yeet.app was not produced (Release WRAPPER_NAME is \$(KERO_DISPLAY_NAME).app)" >&2
  exit 1
fi

rm -rf "$DEST/Yeet.app"
cp -R "$APP" "$DEST/Yeet.app"

# Belt-and-suspenders: never ship the official Sparkle appcast or the
# official EdDSA key on a brew / GitHub Release build of this fork.
# The official key + https://releases.kero.sh would let Sparkle replace
# Yeet with notarized egoist Kero.
PLIST="$DEST/Yeet.app/Contents/Info.plist"
if [[ -f "$PLIST" ]]; then
  plutil -replace SUFeedURL -string "" "$PLIST"
  plutil -replace SUPublicEDKey -string "" "$PLIST"
  plutil -replace SUEnableAutomaticChecks -bool false "$PLIST"
fi

RESOURCES="$DEST/Yeet.app/Contents/Resources"
mkdir -p "$RESOURCES"
cp "$ROOT/LICENSE" "$RESOURCES/LICENSE"
cp "$ROOT/NOTICE" "$RESOURCES/NOTICE"

codesign --force --deep --sign - "$DEST/Yeet.app"
ditto -c -k --keepParent "$DEST/Yeet.app" "$DEST/Yeet.zip"

echo "Built yeet ${VERSION}:"
echo "  $DEST/Yeet.app"
echo "  $DEST/Yeet.zip"
echo
echo "First run on another Mac:"
echo "  xattr -dr com.apple.quarantine \"$DEST/Yeet.app\""
echo "  Then open the app (System Settings → Privacy & Security → Open Anyway if Gatekeeper blocks it)."
