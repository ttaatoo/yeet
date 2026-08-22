# Contributing to Yeet

For anything larger than a fix, open an issue first —
Yeet says no to features that fit some other tool better, and it's kinder to find
that out before the work.

## Setup and build

```bash
git clone https://github.com/ttaatoo/yeet.git
cd yeet
git remote add upstream https://github.com/egoist/kero.git
```

- `origin` — [ttaatoo/yeet](https://github.com/ttaatoo/yeet)
- `upstream` — [egoist/kero](https://github.com/egoist/kero)

Bun is also needed for
`web/` and `scripts/`. Yeet is based on [Kero](https://github.com/egoist/kero). An ad-hoc `Yeet.app` + `Yeet.zip`
is `scripts/package.sh` (used by the in-repo Homebrew tap and the `v*` release
workflow).

A Rust toolchain ([rustup](https://rustup.rs)) is required: the Alacritty
backend's bridge in `Vendor/alacritty-bridge` is a Rust static library, built
from an Xcode build phase. Building for a second architecture needs its target
installed too — `rustup target add x86_64-apple-darwin`.

Open `kero.xcodeproj` and run the `kero` scheme, or:

```bash
xcodebuild -project kero.xcodeproj -scheme kero -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Add `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` if you only have Xcode beta.

A Debug build is `sh.yeet.dev` and keeps its own state, so it can run beside an
installed Yeet without clobbering it: settings go to
`~/.config/yeet-dev/config.toml`, and the session snapshot, sidebar widths, and
Sparkle preferences live under the separate bundle id. Release is `sh.yeet`
and `~/.config/yeet`, so it also sits beside official Kero (`sh.kero`).
If `~/.config/yeet` is missing, leftover `~/.config/kerox` (then older
`~/.config/kero`) is copied in; Debug does the same with `yeet-dev` /
`kerox-dev` / `kero-dev`. Application Support history follows the same idea.

## Website and docs

The site is in [`web/`](web/README.md); user documentation is MDX under
`web/content/docs`. It is written for people using the app — anything that only
matters when you are building it belongs here instead.

## Localization

Yeet’s development language is English, with Simplified Chinese and Japanese
translations maintained in Xcode String Catalogs. See
[LOCALIZATION.md](LOCALIZATION.md) for translating existing text, adding a
language, testing a localization, and writing localizable Swift.

Translation-only pull requests are welcome. Xcode’s catalog editor and XLIFF
export/import workflow both work; contributors do not need to edit Swift.
