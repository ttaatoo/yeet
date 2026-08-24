#!/usr/bin/env bun
//
// Official Kero tap bumper (egoist/homebrew-tap, Casks/kero.rb,
// https://releases.kero.sh/). Yeet pins the in-repo tap instead:
//   bun scripts/pin-homebrew.ts <version>
// See RELEASING.md.
import { join } from "node:path";
import { die } from "./lib";

process.chdir(join(import.meta.dir, ".."));

die(
  "bun scripts/bump-cask.ts targets egoist/homebrew-tap and must not run on this Yeet fork.\n" +
    "         Pin the in-repo tap: bun scripts/pin-homebrew.ts <version>\n" +
    "         See RELEASING.md.",
);
