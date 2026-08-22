# Changelog

All notable changes to Yeet. Official egoist releases used this file as the
source of truth for Sparkle notes via [`scripts/release.ts`](scripts/release.ts).
This repository publishes GitHub Releases (`Yeet.zip`) and has no Sparkle feed;
the matching `## [<version>]` section is still the product changelog.

Format follows [Keep a Changelog](https://keepachangelog.com). Add a new
`## [<version>]` section at the top for each release, matching the version you
set in the Xcode project.

Write release notes for the final product users receive, not the development
history. When a feature is still unreleased, fold its fixes and refinements into
the original feature bullet instead of adding separate entries for them.

## [Unreleased]

- Large files in the editor, including markdown with code fences, open and scroll without dropped frames.
- Rebrand this repository as Yeet (`Yeet.app`, bundle id `sh.yeet`, settings in `~/.config/yeet`). Leftover `~/.config/kerox` (then older `~/.config/kero`) is copied into `~/.config/yeet` when Yeet has no config yet. The same leftover-then-copy applies to Application Support history.
- Drop the project-sidebar Send Feedback button (it opened official Kero Issues).
- Website and install docs describe Yeet: `brew tap ttaatoo/yeet https://github.com/ttaatoo/yeet` then `brew install --cask ttaatoo/yeet/yeet`, `Yeet.zip` from GitHub Releases, no Sparkle, Alacritty only. Upgrade docs pull the in-repo tap first; the FAQ no longer links a disabled Issues page.
