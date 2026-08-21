# frozen_string_literal: true

cask "kero" do
  version "0.1.47"
  sha256 :no_check

  url "https://github.com/ttaatoo/kero/releases/download/v#{version}/Kero.zip"
  name "Kero"
  desc "Keyboard-first terminal workspace with projects, sessions, and git"
  homepage "https://github.com/ttaatoo/kero"

  # MACOSX_DEPLOYMENT_TARGET on the kero target is 15.6 (Sequoia).
  depends_on macos: ">= :sequoia"

  app "Kero.app"

  zap trash: [
    "~/.config/kero",
    "~/Library/Application Support/kero",
    "~/Library/Caches/sh.kero",
    "~/Library/HTTPStorages/sh.kero",
    "~/Library/Preferences/sh.kero.plist",
    "~/Library/Saved Application State/sh.kero.savedState",
    "~/Library/WebKit/sh.kero",
  ]

  caveats <<~EOS
    This is the ttaatoo/kero fork, ad-hoc signed (no Apple Developer ID).
    It is not the notarized app from `brew install egoist/tap/kero`.

    Install with:

      brew tap ttaatoo/kero https://github.com/ttaatoo/kero
      brew install --cask --no-quarantine ttaatoo/kero/kero

    --no-quarantine is required so Gatekeeper does not quarantine the zip.

    If macOS still blocks the app:

      xattr -dr com.apple.quarantine /Applications/Kero.app

    Then System Settings → Privacy & Security → Open Anyway.

    Packaged fork builds do not Sparkle-update from releases.kero.sh
    (that feed would replace this fork with official egoist Kero).
  EOS
end
