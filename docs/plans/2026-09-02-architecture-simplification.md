# Architecture Simplification Implementation Record

**Goal:** Remove inactive Sparkle and terminal-backend contracts, centralize workspace persistence, reduce object-change relays, and retain only Yeet v0.1.47+ snapshot compatibility.
**Scope:** Yeet app sources, project/package metadata, tests, scripts, and supporting documentation. No merge, rebase, release, or unrelated cleanup.
**Assumptions:** The current supported snapshot input is the unversioned multi-window recursive layout introduced before v0.1.47. Older single-window, single-content, and columns layouts are retired.
**Status:** All five approved changes are implemented and locally verified on 2026-09-03. The requested `luna_worker` performed the bounded implementation; the primary agent reviewed, corrected, and verified the combined result. No commit or push was made.
**Baseline:** The checkout was clean at `9b7657a`, with `main` ahead of `origin/main` by one commit and behind by fifteen. No tracking-branch changes were imported. Final test results below are post-change evidence, not a controlled before/after performance comparison.
**Risks:** Persistence migration and observation ownership changes can affect restore, focus, and autosave behavior. This change narrows existing SwiftUI observation boundaries; it does not claim a complete AppKit migration.

## Task 1: Remove inactive Sparkle

Files:
- Delete: `yeet/Updater.swift`
- Modify: `yeet.xcodeproj/project.pbxproj`, `Package.resolved`, `yeet/Info.plist`, `scripts/package.sh`, `NOTICE`, settings/menu/docs/tests as referenced

Steps:
1. Remove the runtime updater object and all UI references.
2. Remove Sparkle package and build metadata, while preserving fail-fast release/appcast scripts.
3. Run Sparkle residue search and project listing.

Result:

- Removed the updater object, settings/menu controls, package reference and pin, Info.plist/build keys, package-script handling, notice entry, and updater-only localization keys.
- The Release app has no Sparkle linkage or updater artifact. Official release/appcast scripts still stop before publishing from this fork.
- Intentional behavior change: this fork no longer advertises inactive automatic-update controls. Manual installation remains documented.
- Retained historical changelog references and the publishing guards because they describe upstream releases or prevent an unsupported action.

## Task 2: Narrow terminal backend contract

Files:
- Modify: `yeet/TerminalBackend.swift`, `yeet/TerminalSession.swift`, `yeet/TerminalHostView.swift`, consumers and focused tests

Steps:
1. Delete unused `TerminalLaunch.commandLine`.
2. Use `AlacrittyTerminalView` as the production surface and retain only consumer-owned test seams.
3. Preserve terminal events, clipboard/URL policy, capture validation, and lifecycle cleanup.
4. Run terminal and find tests plus a focused build.

Result:

- `TerminalSession.surface` and its container use `AlacrittyTerminalView` directly. Deleted the one-implementation `TerminalBackendSurface` and unused launch command string.
- Find and history capture own the small `TerminalFindSurface` and `TerminalScreenExporting` interfaces they need. Terminal events and selection-availability observation remain.
- Kept responder, focus, process cleanup, clipboard/URL policy, and screen-export validation behavior. A second terminal backend is no longer presented as a supported runtime substitution point.

## Task 3: Centralize workspace persistence

Files:
- Create: `yeet/WorkspaceStateStore.swift`
- Modify: `yeet/SessionStore.swift`, `yeet/TerminalHistory.swift`, `yeet/TerminalManager.swift`, `yeet/TerminalSession.swift`, persistence tests

Steps:
1. Define an aggregate load/save boundary with an explicit consistency marker.
2. Migrate the latest unversioned snapshot and history sidecar without destructive overwrite on decode failure.
3. Store `historyKey` on `TerminalSession` and remove associated-object restoration and manager-level dual-store coordination.
4. Run snapshot, history, multi-window close/reopen, and corruption tests.

Result:

- `WorkspaceStateStore` is the application entry point for layout/history load, full save, layout-only save, and pending-write flush. Its defaults and history path can be injected for tests.
- `SessionStore` is the layout codec/storage adapter. The instance-owned `TerminalHistoryStore` retains the serialized sidecar writer and stale-write protection.
- Each full capture gets one generation marker. Layout-only autosave retains that marker and does not rewrite the history sidecar. An encoding failure does not advance either record.
- `TerminalSession.historyKey` replaces associated-object state and the second restoration traversal. Project restoration passes the key and history to the session constructor once.
- Rejected layout bytes are copied to `sessionSnapshotRecovery`; unreadable or unmatched history bytes are copied to the sidecar's `.recovery` path. A failed history recovery copy blocks later history writes for that run.
- The generation marker detects a mismatched pair; it is not an atomic two-file commit. Recovery keeps the layout and omits unmatched history from playback. The recovery bytes remain available for manual recovery.

## Task 4: Remove manager object-change relay

Files:
- Modify: `yeet/TerminalManager.swift`, `yeet/Project.swift`, workspace mutation publisher and affected UI/tests

Steps:
1. Remove the project-to-manager UI invalidation relay and its coalescing state.
2. Add a dedicated workspace mutation event for autosave.
3. Preserve current project/sidebar/tab/header/inspector behavior; do not copy tracking-branch inspector work.
4. Run focused UI/model tests and build.

Result:

- Removed the Project-to-TerminalManager `objectWillChange` relay. A private workspace-mutation publisher still drives debounced autosave without invalidating the whole window.
- The selected workspace, parked projects, header, inspector, sidebar footer, and menu items observe the Project values they display. Command capability state is owned by the focused Project.
- Command-palette and agent-attention consumers use `WorkspaceProjectSnapshotStore`, a derived read-only view of multiple projects. It coalesces a refresh after each mutation burst and releases removed-project subscriptions.
- Kept theme observation, empty-workspace layout, toolbar availability, and inspector-directory synchronization at the affected consumers. This is an observation-boundary change, not a new UI design.

## Task 5: Version and contract snapshot migration

Files:
- Modify: `yeet/SessionStore.swift`, `AppSnapshot` types, legacy identity/settings/theme/skill readers, tests, docs

Steps:
1. Add snapshot version and declare v0.1.47 as the oldest supported input.
2. Keep one migration for the latest unversioned recursive multi-window format.
3. Delete retired older readers and associated fixtures/tests, including Kero/Kerox identity adoption and old settings/theme/skill cleanup.
4. Run migration and restore tests.

Result:

- The writer emits snapshot version 1. The reader accepts version 1 and the last unversioned recursive multi-window representation used by v0.1.47+.
- Removed single-window, columns, and single-content decoding paths and their obsolete success fixtures. Tests now cover rejection and recovery preservation.
- Removed automatic Kero/Kerox data adoption, old font-setting fallback, retired theme aliases, and cleanup of the old automation-skill installation. Existing external legacy installations are not deleted.
- README, contributor/release guidance, English/Chinese installation and configuration pages, and user-visible unreleased changelog entries describe the supported behavior.

## Realized net effect

- Removed one direct package dependency and its runtime subsystem, one broad terminal-backend protocol, duplicate history-key storage/restoration, a whole-window event relay, and obsolete identity/snapshot compatibility paths.
- Added one workspace persistence owner, two small consumer interfaces, one local derived-project store, a version/generation check, and recovery handling for saved data.
- Application Swift is a net increase of 3 lines, including both new production files; Swift tests are a net increase of 570 lines. The benefit is fewer independently maintained contracts and narrower notification scope, not a line-count reduction.
- New test files: `WorkspaceStateStoreTests.swift`, `WorkspaceProjectSnapshotTests.swift`, and `ProjectWorkspaceTests.swift`. Existing snapshot, find, theme, and Git-inspector tests were adjusted at their affected boundaries.

## Verification receipt

All commands ran from the repository root unless another directory is stated.

| Layer | Command or probe | Final result |
| --- | --- | --- |
| Source integrity | `git diff --check`; removed-symbol/dependency searches | Passed; retained historical references and fail-fast guards are intentional |
| Metadata | `bash -n scripts/package.sh`; `plutil -lint yeet/Info.plist yeet.xcodeproj/project.pbxproj`; JSON parse of `yeet/Localizable.xcstrings` | Passed |
| Swift tests | Full macOS Xcode suite shown below | 247 passed, 0 failed, 0 skipped |
| Rust tests | `cargo test --manifest-path Vendor/alacritty-bridge/Cargo.toml --locked` | 99 passed; 0 doctests |
| Website types | In `web`: `/Users/mt/.bun/bin/bun run typecheck` | Passed |
| Website build | In `web`: `/Users/mt/.bun/bin/bun run build` | Passed; 29 pages prerendered |
| Debug build | Xcode Debug build shown below | Passed; ad-hoc signing verification passed |
| Release build | Xcode Release build shown below | Passed on arm64 |
| Release contents | `otool -L` and app-bundle file search | No Sparkle linkage or updater artifact |
| Publishing guards | `/Users/mt/.bun/bin/bun scripts/release.ts`; `/Users/mt/.bun/bin/bun scripts/generate-appcast.ts` | Both returned the intended fail-fast exit code 1; nothing published |
| App behavior | Built Debug app smoke below | Passed for the exercised flows |

```sh
xcodebuild test -project yeet.xcodeproj -scheme yeet -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/yeet-selected-workspace CODE_SIGNING_ALLOWED=NO

xcodebuild -project yeet.xcodeproj -scheme yeet -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/yeet-selected-workspace build

codesign --verify --deep --strict \
  '/tmp/yeet-selected-workspace/Build/Products/Debug/Yeet Debug.app'

xcodebuild -project yeet.xcodeproj -scheme yeet -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/yeet-selected-workspace3 CODE_SIGNING_ALLOWED=NO build
```

Local evidence:

- Swift result bundle: `/tmp/yeet-selected-workspace/Logs/Test/Test-yeet-2026.09.03_00-34-49-+0800.xcresult`.
- Test logs: `/tmp/yeet-architecture-full-tests-final.log` and `/tmp/yeet-architecture-rust-tests.log`.
- Build logs: `/tmp/yeet-architecture-debug-final.log`, `/tmp/yeet-architecture-release-final.log`, and `/tmp/yeet-architecture-web-build.log`.

### Failed check and correction

The first broad post-change suite failed `testLiveUnstagedDiffReloadsWhenSelectedAgain`. The focused run reproduced the failure. The saved Debug preference was `diffView.mode=edit`; the unchanged editor implementation intentionally avoids replacing an editable buffer during diff reload. The test had not established its read-only-mode precondition.

The test now explicitly selects read-only mode and restores the previous raw preference, including an absent value, on exit. Its live-reload assertion remains unchanged. The focused rerun and final full suite passed. Product diff-reload behavior was not changed to satisfy the test.

### App smoke and state restoration

The built Debug app was used for these checks:

- Create and rename a project; observe the new name and working directory in the sidebar, header, project menu, and command palette.
- Split terminals, switch projects, return focus from the palette, toggle pane zoom, and search terminal output.
- Open a local file, open its Replace bar, and open a blank browser tab. Check the browser's disabled Find/Replace/Clear menu actions and the inspector's selected directory.
- Create a fifth window, quit, and reopen. Verify all five windows, the renamed project's three tabs, the restored two-terminal split, and its directory. The saved layout was version 1 with a generation marker.

Before the smoke, Debug defaults and configuration were backed up under `/tmp/yeet-architecture-smoke.ubVONv`. After quitting Debug, its defaults were restored; exported before/after plists compared byte-for-byte equal. The configuration was unchanged, and no terminal-history sidecar was created. The separately running production app was not operated.

### Evidence limits

- Terminal history was disabled in the existing Debug settings. History capture, pairing, recovery, layout-only saves, and restored keys have automated coverage; enabled-history playback was not exercised in the UI.
- No controlled performance benchmark was run. Narrower observation does not establish a measured FPS, latency, memory, or startup gain.
- The verification does not establish all UI interactions, all crash points between physical writes, x86_64 behavior, universal packaging, notarization, or release readiness. Existing broader Swift concurrency warnings remain outside this change.
- The packaging script received a syntax check; full packaging was not run because it also updates submodules and output directories. Release compilation and bundle inspection are separate evidence.

## Recovery and retained scope

- Source recovery is reversal of this task's diff relative to `9b7657a`, including the five new Swift files and this record. No reset, clean, staging, commit, or branch operation was performed. Reverse only this diff if later work has been added.
- A source rollback is not a saved-data rollback. Before using an older build with newly written state, preserve the current layout and history together and restore a matching pre-change backup where available. The smoke backup contains only Debug defaults/configuration; it is not a production data backup.
- Recovery copies preserve rejected data for inspection; they are not automatic conversion of retired formats. Old Kero/Kerox installations are left untouched.
- A full AppKit migration, terminal-event redesign, additional terminal backends, unrelated Git-inspector work from `origin/main`, release publishing, and performance tuning remain outside the approved five cuts.
