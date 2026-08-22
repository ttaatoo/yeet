# frozen_string_literal: true

cask "yeet" do
  version "0.1.50"
  # sha256 of Yeet.zip for this version. Leave :no_check until a Yeet.zip
  # GitHub Release exists — do not invent or reuse a Kerox.zip digest.
  sha256 :no_check

  url "https://github.com/ttaatoo/yeet/releases/download/v#{version}/Yeet.zip"
  name "Yeet"
  desc "Keyboard-first terminal workspace with projects, sessions, and git"
  homepage "https://github.com/ttaatoo/yeet"

  livecheck do
    url :url
    strategy :github_latest
  end

  # MACOSX_DEPLOYMENT_TARGET on the kero target is 15.6 (Sequoia).
  depends_on macos: :sequoia

  app "Yeet.app"

  # Homebrew 5+ removed --no-quarantine. Strip Gatekeeper's attribute so
  # this ad-hoc-signed fork can launch after a normal cask install.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Yeet.app"]
  end

  zap trash: [
    "~/.config/yeet",
    "~/Library/Application Support/yeet",
    "~/Library/Caches/sh.yeet",
    "~/Library/HTTPStorages/sh.yeet",
    "~/Library/Preferences/sh.yeet.plist",
    "~/Library/Saved Application State/sh.yeet.savedState",
    "~/Library/WebKit/sh.yeet",
  ]

  caveats <<~EOS
    This is ttaatoo/yeet, shipped as Yeet (ad-hoc signed, no Apple
    Developer ID). It is based on egoist/kero and is not a GitHub Fork.
    It is not Kerox.app / sh.kerox, and not the notarized app from
    `brew install egoist/tap/kero`. It can sit beside official Kero.app.

    Install with:

      brew tap ttaatoo/yeet https://github.com/ttaatoo/yeet
      brew install --cask ttaatoo/yeet/yeet

    Upgrade with:

      git -C "$(brew --repo ttaatoo/yeet)" pull && brew upgrade --cask ttaatoo/yeet/yeet

    If macOS still blocks the app: System Settings → Privacy & Security
    → Open Anyway.

    Packaged fork builds do not Sparkle-update from releases.kero.sh
    (that feed would replace this fork with official egoist Kero).
  EOS
end
