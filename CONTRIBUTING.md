# Contributing to Yeet

For anything larger than a fix, open an issue first —
Yeet says no to features that fit some other tool better, and it's kinder to find
that out before the work.

By sending a patch you license it under GPL-3.0-only, the same as this
repository. See [LICENSE](LICENSE), [NOTICE](NOTICE), and
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Translation-only pull requests are
welcome; see [LOCALIZATION.md](LOCALIZATION.md).

## Setup and build

```bash
git clone https://github.com/ttaatoo/yeet.git
cd yeet
git remote add upstream https://github.com/egoist/kero.git
rustup target add aarch64-apple-darwin
bun install
```

- `origin` — [ttaatoo/yeet](https://github.com/ttaatoo/yeet)
- `upstream` — [egoist/kero](https://github.com/egoist/kero)

Bun is also needed for
`web/` and `scripts/`. Yeet is based on [Kero](https://github.com/egoist/kero).
Building from this repo is the supported way to get a local app. An ad-hoc
`Yeet.app` + `Yeet.zip` is `scripts/package.sh` (used by the in-repo Homebrew
tap and the `v*` release workflow when a maintainer cuts a GitHub Release).

A Rust toolchain ([rustup](https://rustup.rs)) is required: the Alacritty
backend's bridge in `Vendor/alacritty-bridge` is a Rust static library, built
from an Xcode build phase. The host target is `aarch64-apple-darwin` on Apple
silicon. Building for a second architecture needs
`rustup target add x86_64-apple-darwin` too. The Xcode run-script phase cannot
install targets (sandbox).

Xcode **26.5** or later is enough. Keep the project format at **Xcode 16**
(`objectVersion = 77` in `yeet.xcodeproj/project.pbxproj`). Xcode 27 writes
format `110`, which 26.5 cannot open — decline that upgrade if Xcode offers it.

Debug and Release sign **ad-hoc** (`CODE_SIGN_IDENTITY = "-"`). You do not need
an Apple Developer account or `Config/Local.xcconfig` to press ⌘R.

Open `yeet.xcodeproj` and run the `yeet` scheme, or:

```bash
xcodebuild -project yeet.xcodeproj -scheme yeet -configuration Debug \
  -destination 'platform=macOS,arch=arm64' build

xcodebuild test -project yeet.xcodeproj -scheme yeet \
  -destination 'platform=macOS,arch=arm64'
```

Add `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` if you only have Xcode beta.

A Debug build is `sh.yeet.dev` and keeps its own state, so it can run beside an
installed Yeet without clobbering it: settings go to
`~/.config/yeet-dev/config.toml`, and the session snapshot and sidebar widths
live under the separate bundle id. Release is `sh.yeet`
and `~/.config/yeet`, so it also sits beside official Kero (`sh.kero`).
If `~/.config/yeet` is missing, leftover `~/.config/kerox` (then older
`~/.config/kero`) is copied in; Debug does the same with `yeet-dev` /
`kerox-dev` / `kero-dev`. Application Support history follows the same idea.

## Website and docs

The site is in [`web/`](web/README.md); user documentation is MDX under
`web/content/docs`. It is written for people using the app — anything that only
matters when you are building it belongs here instead.

From the repo root, `bun install`, then in `web/`: `bun run typecheck`. Pull
request CI runs that (and `bun run build`) on Linux, and `xcodebuild test` on
macOS. Website-only changes still run the macOS job.

## Pull requests

Verify the app change: build, run, and exercise it. If you touch `web/` or
`scripts/`, also run `bun run typecheck` in `web/`.

Do not bump `MARKETING_VERSION` or `CURRENT_PROJECT_VERSION` in a PR.
Releases are maintainer-only — see [RELEASING.md](RELEASING.md).

## Localization

Yeet’s development language is English, with Simplified Chinese and Japanese
translations maintained in Xcode String Catalogs. See
[LOCALIZATION.md](LOCALIZATION.md) for translating existing text, adding a
language, testing a localization, and writing localizable Swift.

Translation-only pull requests are welcome. Xcode’s catalog editor and XLIFF
export/import workflow both work; contributors do not need to edit Swift.
