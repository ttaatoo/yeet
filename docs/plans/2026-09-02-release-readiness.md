# Release readiness implementation plan

**Goal:** Make the current Yeet checkout pass its local release gates.
**Scope:** Fix current build, test, analysis, packaging, and runtime failures. Do
not change the version, create a tag, publish an artifact, or update a remote.
**Assumptions:** Apple silicon with Xcode 26.5 or later and the required Rust
target are available.
**Risks:** Local dependency patches can drift from upstream. Keep each patch
documented and reversible.

## Task 1: Close Swift 6 dependency failures

Files:
- Modify: `Vendor/STTextView-Plugin-Neon/Package.swift`
- Create or modify: the narrow local dependency package that owns each error
- Test: the affected package tests and a full Swift 6 Xcode build

Steps:
1. Reproduce the first Swift 6 compiler error.
2. Check the current upstream source and available versions.
3. Patch the smallest owning package and record its upstream revision.
4. Run its Swift 6 package tests.
5. Repeat the full Swift 6 build until it passes.

Done when:
- The full app builds with `SWIFT_VERSION=6`.
- Each local dependency patch has a rollback note.

## Task 2: Run repository gates

Files:
- Modify only files required by a failing gate.

Steps:
1. Run Release build and Debug static analysis.
2. Run the full Xcode test plan and Rust tests.
3. Run Web typecheck and build because CI runs both.
4. Run `git diff --check` and inspect all changed files.

Done when:
- Every supported local and CI-equivalent gate exits with status 0.

## Task 3: Package and run the candidate

Files:
- Do not modify version or release metadata.
- Generated output stays under ignored release directories.

Steps:
1. Run `bash scripts/package.sh`.
2. Start the packaged app and exercise startup, editor, Files, Info, and Git.
3. Check for a crash, freeze, and the original inspector update loop.

Done when:
- The ad-hoc app and zip exist.
- The packaged app remains responsive during the smoke test.

## Rollback

Restore each dependency manifest to its remote URL, remove the corresponding
local vendor directory, and resolve packages again. Revert only files created
or changed by this plan.
