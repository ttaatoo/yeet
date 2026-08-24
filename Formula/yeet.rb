# frozen_string_literal: true

class Yeet < Formula
  desc "Keyboard-first terminal workspace with projects, sessions, and git"
  homepage "https://github.com/ttaatoo/yeet"
  # Source-build formula: compiles Yeet.app on this Mac. The cask
  # (`Casks/yeet.rb`) downloads Yeet.zip when a GitHub Release includes
  # that asset and a pinned sha256. Do not use sha256 :no_check.
  url "https://github.com/ttaatoo/yeet/archive/refs/tags/v0.1.52.tar.gz"
  sha256 "3e39aec5667b062a81e44431a09dea87bec2b974c5881500b2ddd7eb7282d263"
  license "GPL-3.0-only"
  head "https://github.com/ttaatoo/yeet.git", branch: "main"

  # MACOSX_DEPLOYMENT_TARGET on the yeet target is 15.6 (Sequoia).
  depends_on macos: :sequoia
  depends_on xcode: :build
  depends_on "rust" => :build

  def install
    system "bash", "scripts/package.sh"
    prefix.install "dist/Yeet.app"
    # The app executable is itself the bundled `yeet` CLI
    # (Yeet.app/Contents/MacOS/yeet; prepended to PATH inside Yeet
    # terminals). Do not install a Homebrew `bin/yeet` that only `open`s
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

      Builds are ad-hoc signed. This formula does not strip Gatekeeper
      quarantine. If macOS blocks the app: System Settings → Privacy &
      Security → Open Anyway.

      --HEAD compiles on this Mac. You need Xcode 26.5 or later plus Rust
      (alacritty-bridge).

      The bundled CLI is #{prefix}/Yeet.app/Contents/MacOS/yeet
      (already on PATH inside Yeet terminals).

      Packaged fork builds do not Sparkle-update from releases.kero.sh
      (that feed would replace this fork with official egoist Kero).
    EOS
  end

  test do
    assert_path_exists prefix/"Yeet.app"
  end
end
