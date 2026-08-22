# Security Policy

## Supported Versions

Only the latest release of Yeet receives security fixes. This repository ships
ad-hoc-signed GitHub Release zips (`Yeet.zip`) and an in-repo Homebrew cask.
There is no Sparkle feed; do not expect updates from `https://kero.sh` or
`https://releases.kero.sh`.

## Reporting a Vulnerability

Please use GitHub private vulnerability reporting:
https://github.com/ttaatoo/yeet/security/advisories/new

Please don't open a public issue for anything you believe is
exploitable before it has been fixed. Include reproduction steps and
the Yeet version (Yeet → About Yeet) you tested.

Vulnerabilities that also affect official [egoist/kero](https://github.com/egoist/kero)
should be reported there as well:
https://github.com/egoist/kero/security/advisories/new
or hi@egoist.dev.

## Scope

Yeet embeds an Alacritty terminal surface (the Rust bridge in
`Vendor/alacritty-bridge`) and implements the Kitty graphics protocol
there. Ghostty / libghostty is not part of this fork. In scope here:
Yeet's configuration and host integration of that surface — clipboard
access, escape-sequence handling that crosses a trust boundary, the
install/update path (Homebrew cask and GitHub Releases), and anything
that lets terminal output reach data outside the session.
Vulnerabilities in upstream Alacritty should also be reported to the
Alacritty project: https://github.com/alacritty/alacritty/security.
