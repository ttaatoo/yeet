# frozen_string_literal: true

class Yeet < Formula
  desc "Keyboard-first terminal workspace with projects, sessions, and git"
  homepage "https://github.com/ttaatoo/yeet"
  # Source-build fallback. The supported install is the cask
  # (`brew install --cask ttaatoo/yeet/yeet`), which downloads Yeet.zip
  # from GitHub Releases. This formula compiles Yeet.app on the Mac.
  url "https://github.com/ttaatoo/yeet/archive/refs/tags/v0.1.50.tar.gz"
  sha256 "fddf2bf99ec39e8465d2f892b3e52f65897dbe579420f180a2a9d29c9cd0550b"
  license "GPL-3.0-only"
  head "https://github.com/ttaatoo/yeet.git", branch: "main"

  # MACOSX_DEPLOYMENT_TARGET on the kero target is 15.6 (Sequoia).
  depends_on macos: :sequoia
  depends_on xcode: :build
  depends_on "rust" => :build

  def install
    system "bash", "scripts/package.sh"
    prefix.install "dist/Yeet.app"
    system "/usr/bin/xattr", "-dr", "com.apple.quarantine", "#{prefix}/Yeet.app"
    # The app executable is itself the bundled `kero` CLI
    # (Yeet.app/Contents/MacOS/kero; prepended to PATH inside Yeet
    # terminals). Do not install a Homebrew `bin/kero` that only `open`s
    # the GUI — that would collide with the CLI name.
  end

  def caveats
    <<~EOS
      This is ttaatoo/yeet, shipped as Yeet (ad-hoc signed, no Apple
      Developer ID). It is based on egoist/kero and is not a GitHub Fork.
      It is not Kerox.app / sh.kerox, and not the notarized app from
      `brew install egoist/tap/kero`. It can sit beside official Kero.app.

      Optional symlink:

        ln -sf #{prefix}/Yeet.app /Applications/Yeet.app

      If macOS still blocks the app: System Settings → Privacy & Security
      → Open Anyway.

      --HEAD compiles on this Mac. The Xcode project uses format 110
      (LastUpgradeCheck 2700) and has already failed on Xcode 26.5; you
      need a newer Xcode plus Rust (alacritty-bridge).

      The bundled CLI is #{prefix}/Yeet.app/Contents/MacOS/kero
      (already on PATH inside Yeet terminals).

      Packaged fork builds do not Sparkle-update from releases.kero.sh
      (that feed would replace this fork with official egoist Kero).
    EOS
  end

  test do
    assert_path_exists prefix/"Yeet.app"
  end
end
