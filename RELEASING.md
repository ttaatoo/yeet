# Releasing Yeet

Maintainer-only. Pull requests must not bump `MARKETING_VERSION` or
`CURRENT_PROJECT_VERSION`.

Yeet has no Apple Developer ID and no Sparkle feed. Do not run
`bun scripts/release.ts` / `bun run release` / `bun run appcast` /
`bun scripts/bump-cask.ts`. Those commands fail fast so they cannot
publish to official Kero R2 (`https://releases.kero.sh`) or
`egoist/homebrew-tap`.

## Cut a release

1. Set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
   `yeet.xcodeproj/project.pbxproj` (Debug and Release match).
2. Move the `[Unreleased]` notes in `CHANGELOG.md` into a
   `## [<version>]` section at the top.
3. Build the ad-hoc zip:

   ```bash
   bash scripts/package.sh
   ```

   Output: `dist/Yeet.app` and `dist/Yeet.zip`.
4. Pin the in-repo Homebrew tap to that zip (and the GitHub source
   tarball once the tag exists — run this again after the tag is on
   GitHub if the formula sha256 was skipped):

   ```bash
   bun scripts/pin-homebrew.ts <version>
   ```

   Do not use `sha256 :no_check`. Do not invent a digest.
5. Commit the version bump, changelog, and Homebrew pins.
6. Push a `v*` tag (or run the Release workflow). The workflow builds
   `Yeet.zip` on `macos-26` (Xcode 26.x), attaches it to the GitHub
   Release, and pins `Casks/yeet.rb` / `Formula/yeet.rb` on `main`.

Users upgrade with:

```bash
git -C "$(brew --repo ttaatoo/yeet)" pull && brew upgrade --cask ttaatoo/yeet/yeet
```

Packaged Release builds clear `SUFeedURL` and `SUPublicEDKey` so Sparkle
cannot replace Yeet with official egoist Kero. Debug uses the same empty
feed and empty key. Keep `yeet.xcodeproj` at Xcode 16 project format
(`objectVersion = 77`). Xcode 27 writes format `110`, which 26.5 cannot
open.

If GitHub-hosted macOS runners cannot build, produce `dist/Yeet.zip` on
a Mac with Xcode 26.5+ and Rust, attach it to the release, then run
`bun scripts/pin-homebrew.ts <version>` and push the pin to `main`.

## What this fork does not ship

- Developer ID signing and notarization
- Sparkle appcast / delta updates
- Uploads to `https://releases.kero.sh`
- Bumps of `egoist/homebrew-tap`

Those belong to [egoist/kero](https://github.com/egoist/kero).
