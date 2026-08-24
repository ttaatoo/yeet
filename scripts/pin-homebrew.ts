#!/usr/bin/env bun
//
// Pin the in-repo Homebrew tap to a built Yeet.zip (cask) and, when the
// GitHub tag exists, to the source tarball (formula).
//
//   bun scripts/pin-homebrew.ts 0.1.51
//   bun scripts/pin-homebrew.ts 0.1.51 dist/Yeet.zip
import { existsSync } from "node:fs";
import { join } from "node:path";
import { die, say } from "./lib";

process.chdir(join(import.meta.dir, ".."));

const versionArg = process.argv[2];
const zipPath = process.argv[3] ?? "dist/Yeet.zip";
if (!versionArg) die("usage: bun scripts/pin-homebrew.ts <version> [zip]");
if (versionArg.startsWith("v")) {
  die("pass the version without a v prefix, for example 0.1.51");
}
if (!existsSync(zipPath)) die(`missing ${zipPath} — run bash scripts/package.sh first`);

const sha256Hex = async (bytes: ArrayBuffer): Promise<string> =>
  new Bun.CryptoHasher("sha256").update(bytes).digest("hex");

const zipSha = await sha256Hex(await Bun.file(zipPath).arrayBuffer());
const tag = `v${versionArg}`;

let cask = await Bun.file("Casks/yeet.rb").text();
cask = cask.replace(/version "[^"]+"/, `version "${versionArg}"`);
if (cask.includes("sha256 :no_check")) {
  cask = cask.replace(/sha256 :no_check/, `sha256 "${zipSha}"`);
} else {
  cask = cask.replace(/sha256 "[0-9a-fA-F]+"/, `sha256 "${zipSha}"`);
}
if (!cask.includes(`version "${versionArg}"`) || !cask.includes(zipSha)) {
  die("failed to rewrite Casks/yeet.rb (version or sha256 pattern missed)");
}
await Bun.write("Casks/yeet.rb", cask);
say(`Casks/yeet.rb → ${versionArg} sha256 ${zipSha}`);

const tarUrl = `https://github.com/ttaatoo/yeet/archive/refs/tags/${tag}.tar.gz`;
const tarRes = await fetch(tarUrl);
if (!tarRes.ok) {
  say(
    `Formula/yeet.rb left unchanged: ${tarUrl} returned ${tarRes.status}. ` +
      `Push the ${tag} tag, then re-run this script.`,
  );
  process.exit(0);
}
const tarSha = await sha256Hex(await tarRes.arrayBuffer());
let formula = await Bun.file("Formula/yeet.rb").text();
formula = formula.replace(
  /url "https:\/\/github.com\/ttaatoo\/yeet\/archive\/refs\/tags\/v[^"]+"/,
  `url "${tarUrl}"`,
);
formula = formula.replace(/sha256 "[0-9a-fA-F]+"/, `sha256 "${tarSha}"`);
if (!formula.includes(tarUrl) || !formula.includes(tarSha)) {
  die("failed to rewrite Formula/yeet.rb (url or sha256 pattern missed)");
}
await Bun.write("Formula/yeet.rb", formula);
say(`Formula/yeet.rb → ${tarUrl} sha256 ${tarSha}`);
