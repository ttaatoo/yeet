#!/usr/bin/env bun
//
// Official egoist/kero Sparkle + R2 + homebrew-tap publisher.
// ttaatoo/yeet must not run it — it would upload to releases.kero.sh
// and bump egoist/homebrew-tap.
//
// Yeet: bash scripts/package.sh, then bun scripts/pin-homebrew.ts <version>.
// GitHub Release: push a v* tag or run the Release workflow.
// See RELEASING.md.
import { join } from "node:path";
import { die } from "./lib";

process.chdir(join(import.meta.dir, ".."));

die(
  "bun run release is the official Kero Sparkle/R2/tap flow and must not run on this Yeet fork.\n" +
    "         Ad-hoc zip: bash scripts/package.sh\n" +
    "         Pin Homebrew: bun scripts/pin-homebrew.ts <version>\n" +
    "         GitHub Release: push a v* tag or run the Release workflow.\n" +
    "         See RELEASING.md.",
);
