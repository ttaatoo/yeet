# frozen_string_literal: true

class Kerox < Formula
  desc "Keyboard-first terminal workspace with projects, sessions, and git"
  homepage "https://github.com/ttaatoo/kero"
  # Versioned tarball for a future v0.1.47 (or later) tag. Until that
  # archive exists, install from git:
  #   brew install --formula --HEAD ttaatoo/kero/kerox
  url "https://github.com/ttaatoo/kero/archive/refs/tags/v0.1.47.tar.gz"
  sha256 :no_check
  license "GPL-3.0-only"
  head "https://github.com/ttaatoo/kero.git", branch: "main"

  # MACOSX_DEPLOYMENT_TARGET on the kero target is 15.6 (Sequoia).
  depends_on macos: :sequoia
  depends_on xcode: :build
  depends_on "rust" => :build

  def install
    system "bash", "scripts/package.sh"
    prefix.install "dist/Kerox.app"
    system "/usr/bin/xattr", "-dr", "com.apple.quarantine", "#{prefix}/Kerox.app"
    # The app executable is itself the bundled `kero` CLI
    # (Kerox.app/Contents/MacOS/kero; prepended to PATH inside Kerox
    # terminals). Do not install a Homebrew `bin/kero` that only `open`s
    # the GUI — that would collide with the CLI name.
  end

  def caveats
    <<~EOS
      This is the ttaatoo/kero fork, shipped as Kerox (ad-hoc signed, no
      Apple Developer ID). It is not the notarized app from
      `brew install egoist/tap/kero` and can sit beside official Kero.app.

      Optional symlink:

        ln -sf #{prefix}/Kerox.app /Applications/Kerox.app

      If macOS still blocks the app: System Settings → Privacy & Security
      → Open Anyway.

      --HEAD compiles on this Mac. The Xcode project uses format 110
      (LastUpgradeCheck 2700) and has already failed on Xcode 26.5; you
      need a newer Xcode plus Rust (alacritty-bridge).

      The bundled CLI is #{prefix}/Kerox.app/Contents/MacOS/kero
      (already on PATH inside Kerox terminals).

      Packaged fork builds do not Sparkle-update from releases.kero.sh
      (that feed would replace this fork with official egoist Kero).
    EOS
  end

  test do
    assert_path_exists prefix/"Kerox.app"
  end
end
