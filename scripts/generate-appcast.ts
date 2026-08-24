#!/usr/bin/env bun
//
// Official Kero Sparkle appcast generator. Defaults would write enclosure
// URLs on https://releases.kero.sh/. Yeet has no Sparkle feed.
// See RELEASING.md.
import { join } from "node:path";
import { die } from "./lib";

process.chdir(join(import.meta.dir, ".."));

die(
  "bun run appcast is the official Kero Sparkle appcast flow and must not run on this Yeet fork.\n" +
    "         Ad-hoc zip: bash scripts/package.sh\n" +
    "         Pin Homebrew: bun scripts/pin-homebrew.ts <version>\n" +
    "         See RELEASING.md.",
);
