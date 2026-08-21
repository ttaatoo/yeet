# frozen_string_literal: true

cask "kerox" do
  version "0.1.47"
  sha256 :no_check

  url "https://github.com/ttaatoo/kero/releases/download/v#{version}/Kerox.zip"
  name "Kerox"
  desc "Keyboard-first terminal workspace with projects, sessions, and git"
  homepage "https://github.com/ttaatoo/kero"

  # MACOSX_DEPLOYMENT_TARGET on the kero target is 15.6 (Sequoia).
  depends_on macos: :sequoia

  app "Kerox.app"

  # Homebrew 5+ removed --no-quarantine. Strip Gatekeeper's attribute so
  # this ad-hoc-signed fork can launch after a normal cask install.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Kerox.app"]
  end

  zap trash: [
    "~/.config/kerox",
    "~/Library/Application Support/kerox",
    "~/Library/Caches/sh.kerox",
    "~/Library/HTTPStorages/sh.kerox",
    "~/Library/Preferences/sh.kerox.plist",
    "~/Library/Saved Application State/sh.kerox.savedState",
    "~/Library/WebKit/sh.kerox",
  ]

  caveats <<~EOS
    This is the ttaatoo/kero fork, shipped as Kerox (ad-hoc signed, no
    Apple Developer ID). It is not the notarized app from
    `brew install egoist/tap/kero` and can sit beside official Kero.app.

    Install with:

      brew tap ttaatoo/kero https://github.com/ttaatoo/kero
      brew install --cask ttaatoo/kero/kerox

    If macOS still blocks the app: System Settings → Privacy & Security
    → Open Anyway.

    Packaged fork builds do not Sparkle-update from releases.kero.sh
    (that feed would replace this fork with official egoist Kero).
  EOS
end
