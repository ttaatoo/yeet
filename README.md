# Kero

A native terminal workspace for macOS.

![preview](https://kero.sh/kero-screenshot.png)

## Install

This repository is the **ttaatoo/kero** fork. Builds are **ad-hoc signed** (no Apple Developer Program / Developer ID). That is **not** the notarized upstream app.

```bash
brew tap ttaatoo/kero https://github.com/ttaatoo/kero
brew install --cask --no-quarantine ttaatoo/kero/kero
# until a GitHub Release zip exists:
brew install --formula --HEAD ttaatoo/kero/kero
```

Do **not** use `brew install egoist/tap/kero` if you want this fork. That command installs official [egoist/kero](https://github.com/egoist/kero) (Developer ID, Sparkle from `https://releases.kero.sh`). Both produce `Kero.app`; installing one replaces the other.

`--no-quarantine` is required for the ad-hoc cask. The cask downloads `Kero.zip` from this repo's GitHub Releases (`v0.1.47`, app name `Kero.app`). Until that asset exists, use the HEAD formula.

`--HEAD` compiles on your Mac. You need a **new-enough Xcode** (this project uses format `110` / LastUpgradeCheck `2700` and has already failed on Xcode 26.5) plus a [Rust toolchain](https://rustup.rs) for `Vendor/alacritty-bridge`.

If Gatekeeper still blocks it:

```bash
# cask
xattr -dr com.apple.quarantine /Applications/Kero.app
# formula
xattr -dr com.apple.quarantine "$(brew --prefix kero)/Kero.app"
```

Then **System Settings → Privacy & Security → Open Anyway**.

Packaged fork builds do not Sparkle-update from `releases.kero.sh` — that feed would overwrite this fork with official egoist Kero.

Ad-hoc zip without Homebrew: `./scripts/package.sh` writes `dist/Kero.app` and `dist/Kero.zip`. Pushing a `v*` tag (or running the Release workflow) uploads that zip. GitHub-hosted macOS runners may fail if their Xcode is older than the project format; in that case build on a Mac and attach the zip to the release.

## Official download

The notarized upstream build is at https://kero.sh or `brew install egoist/tap/kero`.

## Features

- Native AppKit interface for projects, tabs, and split panes
- GPU-accelerated Alacritty terminal backend
- Integrated browser tabs and panes
- File tree, Git status, and editable diffs
- Command palette, project-wide file search, and local path links
- AI agents can delegate background work and coordinate across Kero panes, with provider-reported status and human-controlled approvals

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md)

## License

GPLv3
