# Yeet

A native terminal workspace for macOS. **Yeet** is based on [Kero](https://github.com/egoist/kero) (EGOIST) and is published as an independent repository at [ttaatoo/yeet](https://github.com/ttaatoo/yeet). It is **not** a GitHub Fork of egoist/kero, and it is **not** Kerox.app / `sh.kerox`.

![preview](https://kero.sh/kero-screenshot.png)

## Install

Builds are **ad-hoc signed** (no Apple Developer Program / Developer ID). That is **not** the notarized upstream app.

```bash
brew tap ttaatoo/yeet https://github.com/ttaatoo/yeet
brew install --cask ttaatoo/yeet/yeet
```

Upgrade (pull the in-repo tap first):

```bash
git -C "$(brew --repo ttaatoo/yeet)" pull && brew upgrade --cask ttaatoo/yeet/yeet
```

Do **not** use `brew install egoist/tap/kero` if you want Yeet. That command installs official [egoist/kero](https://github.com/egoist/kero) (Developer ID, Sparkle from `https://releases.kero.sh`) as `Kero.app` / `sh.kero`. Yeet installs `Yeet.app` / `sh.yeet` and keeps settings in `~/.config/yeet` (Debug: `~/.config/yeet-dev`).

If `~/.config/yeet` is missing, Yeet copies leftover `~/.config/kerox` when that directory exists, otherwise older `~/.config/kero`. The same leftover-then-copy applies to Application Support history.

The cask downloads `Yeet.zip` from this repo's GitHub Releases. After install, the cask strips Gatekeeper quarantine so the ad-hoc app can launch.

If macOS still blocks the app: **System Settings → Privacy & Security → Open Anyway**.

Packaged Yeet builds do not Sparkle-update from `releases.kero.sh` — that feed would overwrite this app with official egoist Kero. There is no official Yeet Sparkle feed. Use the Homebrew upgrade above (or reinstall the cask). There is no in-app updater on packaged builds.

Ad-hoc zip without Homebrew: `./scripts/package.sh` writes `dist/Yeet.app` and `dist/Yeet.zip`. Pushing a `v*` tag (or running the Release workflow) uploads that zip. GitHub-hosted macOS runners may fail if their Xcode is older than the project format; in that case build on a Mac and attach the zip to the release.

Compiling from source (`brew install --formula --HEAD ttaatoo/yeet/yeet`) needs a **new-enough Xcode** (this project uses format `110` / LastUpgradeCheck `2700` and has already failed on Xcode 26.5) plus a [Rust toolchain](https://rustup.rs) for `Vendor/alacritty-bridge`. The cask is the supported install path.

## Official download

The notarized upstream Kero build is at https://kero.sh or `brew install egoist/tap/kero`.

## Clone remotes

```bash
git clone https://github.com/ttaatoo/yeet.git
cd yeet
git remote add upstream https://github.com/egoist/kero.git
```

- `origin` — [ttaatoo/yeet](https://github.com/ttaatoo/yeet)
- `upstream` — [egoist/kero](https://github.com/egoist/kero)

## Differences from Kero

| | Official Kero | Yeet |
| --- | --- | --- |
| App | `Kero.app` | `Yeet.app` (Debug: `Yeet Debug.app`) |
| Bundle id | `sh.kero` | `sh.yeet` / `sh.yeet.dev` |
| Config | `~/.config/kero` | `~/.config/yeet` (Debug: `yeet-dev`) |
| Homebrew | `egoist/tap/kero` | `brew tap ttaatoo/yeet https://github.com/ttaatoo/yeet` then `brew install --cask ttaatoo/yeet/yeet` |
| Zip | notarized `.dmg` | `Yeet.zip` |
| Sparkle | `https://releases.kero.sh` | none (empty feed; do not use the official Kero feed) |
| Signing | Developer ID | ad-hoc |
| Repository | [egoist/kero](https://github.com/egoist/kero) | [ttaatoo/yeet](https://github.com/ttaatoo/yeet) (independent; not a GitHub Fork) |

Internal names stay `kero` on purpose: `kero.xcodeproj`, the `kero` scheme, `PRODUCT_NAME = kero` (bundled CLI still `kero`), `kero_alacritty`, `KeroTerminal`, `KeroCell`, `KeroAutomation*`, skill id `kero-automation`, and env/build names `KERO_TERM` / `KERO_DISPLAY_NAME` / `KERO_SU_*`.

This is also not the previous Kerox shipping identity (`Kerox.app` / `sh.kerox` / `~/.config/kerox`). Leftover Kerox (then older Kero) config and Application Support are copied into Yeet paths only when Yeet has none yet.

## Features

- Native AppKit interface for projects, tabs, and split panes
- GPU-accelerated Alacritty terminal backend
- Integrated browser tabs and panes
- File tree, Git status, and editable diffs
- Command palette, project-wide file search, and local path links
- AI agents can delegate background work and coordinate across Yeet panes, with provider-reported status and human-controlled approvals

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md)

## License

GPLv3. See [LICENSE](LICENSE) and [NOTICE](NOTICE). Existing Kero / EGOIST copyrights are preserved; Yeet modifications add a copyright line in NOTICE.
