# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Yeet is a native macOS terminal workspace with projects, panes, a file tree, a git panel,
an editor, and a diff viewer. It is a fork of Kero (upstream remote `egoist/kero`); Swift
sources use the internal `Kero`/`kero` prefix, while the product, scheme, and bundle are
`yeet`/`Yeet`. Existing SwiftUI code is legacy; AppKit is the UI foundation.

- [PRODUCT.md](PRODUCT.md) — who Yeet is for; product and design calls follow from it.
- [CONTRIBUTING.md](CONTRIBUTING.md) — build, verify, and what a PR must say. Read before opening one.
- [RELEASING.md](RELEASING.md) — maintainer-only. Never bump the version in a PR.
- [LOCALIZATION.md](LOCALIZATION.md) — String Catalogs; en is the development language, zh-Hans and ja are maintained.

## Build and test

Prerequisites: Xcode **26.5+** (keep the project format at Xcode 16, `objectVersion = 77`
in the pbxproj — Xcode 27's format 110 breaks 26.5), a Rust toolchain (rustup; the
Alacritty bridge build phase needs it even for Debug builds, and `rustup target add` cannot
run from the sandboxed build phase — install targets first), and bun for `web/` and `scripts/`.

```bash
# build (or open yeet.xcodeproj and run the `yeet` scheme)
xcodebuild -project yeet.xcodeproj -scheme yeet -configuration Debug \
  -destination 'platform=macOS,arch=arm64' build

# all tests (yeet.xctestplan → yeetTests)
xcodebuild test -project yeet.xcodeproj -scheme yeet \
  -destination 'platform=macOS,arch=arm64'

# one test class
xcodebuild test -project yeet.xcodeproj -scheme yeet \
  -destination 'platform=macOS,arch=arm64' -only-testing:yeetTests/GitPorcelainTests

# web / scripts (repo root)
bun install && cd web && bun run typecheck

# STTextView scroll-perf gate (vendored patches must keep ≥114 FPS)
scripts/bench-file-render.sh

# Git inspector data-path bench (133 staged / 3 unstaged / 60 commits → JSON)
scripts/bench-git-inspector.sh
```

Debug builds are `sh.yeet.dev` with state in `~/.config/yeet-dev`, so they run beside an
installed Yeet. Release is `sh.yeet` / `~/.config/yeet`.

## Architecture

### Terminal pipeline

`yeet/TerminalBackend.swift` defines the emulator-agnostic contract: `TerminalLaunch`,
`TerminalBackendSurface` (an `NSView` protocol), `TerminalBackendEvents`. `TerminalSession`
owns one PTY process plus one surface; its launch script writes a `shell.pid` file, replays
saved scrollback from `history.vt`, and `exec`s the shell with `YEET_TERM=alacritty` /
`TERM_PROGRAM=Yeet`. `yeet/Alacritty/AlacrittyTerminalView.swift` is the only surface
(pure AppKit): it drives the C API in `Vendor/alacritty-bridge/include/kero_alacritty.h`,
bounces Rust events to the main thread, coalesces redraws on `CADisplayLink`, and draws
snapshots via `TerminalMetalRenderer` (one instanced draw call; glyphs from
`TerminalGlyphAtlas`). The bridge is a Rust static library around the `alacritty_terminal`
crate, built by an Xcode run-script phase (`scripts/build-alacritty-bridge.sh`); it always
runs `cargo build --release` (a debug VT parser is perceptibly slow) and builds from a
`TARGET_TEMP_DIR` copy because of user-script sandboxing. `kero_alacritty.h` is
hand-maintained — keep it in step with the `#[repr(C)]` structs in
`Vendor/alacritty-bridge/src/lib.rs`.

### Automation / agent IPC

External agents drive Yeet from *inside* a terminal pane. `KeroCLIService` creates a private
unix-domain socket (NDJSON, one request/response per connection, 1 MiB cap) and injects
`YEET_AUTOMATION_SOCKET`, `YEET_AUTOMATION_TOKEN` (a per-terminal capability token), and the
app bin dir into `PATH` of every spawned shell. The `yeet` CLI is the same app binary:
`yeet/main.swift` runs `KeroCommandLine` when the bridge env is present or argv starts with
`+` (`yeet +pane split`, `yeet +agent start`), which opens the socket from env and prints
JSON. Requests route through `KeroAutomationRouter` (`protocol.info`, `pane.*`, `agent.*`);
authorization is scoped to the invoking terminal's project — cross-project targets are
rejected. Agent status (`AgentAutomation.swift`) carries an authority: `.command`,
`.process` (PID recognition), or `.integration`; only `.integration` reports are trusted for
`agent.wait`/`read`. Integrations in `yeet/AgentIntegrations/{grok,opencode,pi}/` install as
versioned symlinks into each agent's config dir. The bundled skill teaching agents the
workflow is `yeet/Skills/yeet-automation/SKILL.md` (exported as `YEET_AUTOMATION_SKILL`).

### State model

One `TerminalManager` per window → `[Project]` → `Project.tabs: [PaneTab]` → recursive
split tree whose leaves are `PaneContent` (`.session | .file | .browser | .diff`,
`Panes.swift`). `SessionStore` persists a `SessionSnapshot` to UserDefaults (key
`"sessionSnapshot"`; decoders keep three historical layout formats alive): projects, tab and
pane trees, split fractions, cwd/paths/URLs, panel visibility, plus VT scrollback sidecars.
Processes do not survive restart — fresh shells spawn in the last cwd and replay saved
scrollback. `TerminalHostView` reparents the same AppKit surface across tab and split
changes so PTY state, selection, and scrollback survive. Git state is plain `/usr/bin/git`
(`status --porcelain=v2 -z` etc., `GIT_OPTIONAL_LOCKS=0`) parsed by custom NUL-delimited
code in `GitStatusModel.swift` — no libgit2. Its porcelain parser is covered by
`yeetTests/GitPorcelainTests.swift`.

### Vendored code

`Vendor/STTextView` is upstream 2.3.11 plus exactly 12 local patches marked `kero patch` —
read `Vendor/STTextView/KERO_PATCHES.md` before touching it; re-vendoring must re-apply
every patch (grep `kero patch`). `Vendor/STTextView-Plugin-Neon/KERO.md` and
`Vendor/TreeSitterTSX/` have their own rules: never add a remote STTextView dependency
(duplicate SwiftPM identity crashes Xcode) and never create a second `Package.swift` under
those directories. `scripts/package.sh` fails if more than the three known Vendor
`Package.swift` manifests exist.

## Verify

Build, run the app, exercise the change.

## Conventions

- Match the file you're in. Comments explain *why* — keep them, add them.
- SwiftUI is legacy and must not be introduced or expanded. Build all new UI in AppKit;
  when materially changing an existing SwiftUI view, migrate the affected UI to AppKit.
  Legacy SwiftUI remains in `ContentView`, `RightSidebarView`, `PaneLayoutView`, and the
  settings chrome; they reach AppKit through `NSViewRepresentable` shims. The terminal
  surface stack is pure AppKit.
- UI architecture must prioritize maximum runtime performance over implementation convenience.
- There is no `@main`; `yeet/main.swift` is top-level code (CLI dispatch first, then
  `keroApp.main()`). Each window owns its own `TerminalManager`.
- `MainActorIsolation.swift` provides `assumeMainActor(_:)` for input paths where the main
  thread is structural (AppKit monitors, main-queue notifications); prefer it there over
  `MainActor.assumeIsolated`.
- [CHANGELOG.md](CHANGELOG.md) is the product changelog for end users, not a
  development log. Describe only the final user-visible outcome intended to
  ship. Never add or revise release notes for incremental fixes, refactors,
  implementation details, or regressions introduced and resolved while a
  feature is still in progress on an unreleased branch.
