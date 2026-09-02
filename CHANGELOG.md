# Changelog

All notable changes to Yeet. Official egoist releases used this file as the
source of truth for Sparkle notes via [`scripts/release.ts`](scripts/release.ts).
This repository publishes GitHub Releases (`Yeet.zip`) and has no Sparkle feed;
the matching `## [<version>]` section is still the product changelog.

Format follows [Keep a Changelog](https://keepachangelog.com). Add a new
`## [<version>]` section at the top for each release, matching the version you
set in the Xcode project.

Write release notes for the final product users receive, not the development
history. When a feature is still unreleased, fold its fixes and refinements into
the original feature bullet instead of adding separate entries for them.

## [Unreleased]

- `yeet +agent start` waits inside Yeet for process recognition instead of polling from the CLI.
- Starting an agent can use its own git worktree so parallel agents do not share one dirty tree.

## [0.1.57]

- Restoring a Git project no longer crashes Yeet when its status contains duplicate or Unicode-equivalent paths.

## [0.1.56]

- `yeet +agent wait` and `yeet +agent prompt --wait` wait inside Yeet for a provider-reported or recognized agent state instead of polling from the CLI. A timeout is the structured error `wait_timeout`.

## [0.1.55]

- Settings → Colors has an Accent picker: Coral (the current orange and mint) or Vivid Purple. It recolors the selected-project stripe and agent indicator; blocked agents stay coral-red so they do not match the purple stripe.
- IME candidate windows and inline composition stay on the insertion point when a terminal program hides its cursor.

## [0.1.54]

- Agent and project status is clearer: starting agents use a short arc, finished or interrupted Grok turns stop the spinner, project metadata stays aligned, and split-pane status bars remain inside the focus ring.
- Terminal selection uses the theme selection color and clears on a click or keystroke, including when a mouse-aware TUI such as Grok is active.
- Terminal panes stay responsive during heavy output: typing reaches terminal programs promptly, and Find keeps its query and last count while output refreshes results.

## [0.1.53]

- Yeet Dark and Yeet Light are the default themes. Dark chrome is a warm near-black frame with an orange selection mark and a mint cursor; light chrome uses warm paper. Older `Default Dark` / `Default Light` names in `config.toml` still load these built-ins.
- When an agent finishes with uncommitted files, the project row shows a file count. Shift-Cmd-A and the command palette Pending Review section open Git so you can inspect, stage, or discard. Focusing the pane quiets the agent badge; the file count stays until Git is clean.
- The empty window shows the Yeet mascot and an Open a repository prompt.
- The project list defaults narrower. Split panes mark the focused header and show a 1-point mint bar on an agent that is working or finished. Ctrl-Tab cards show agent state and a pending file count.
- Dragging left or right in a terminal selects text on that line.

## [0.1.52]

- Opening a project no longer creates a `default.profraw` file in that folder.
- Terminal programs can copy with OSC 52 without a confirmation. Settings → Terminal → Clipboard write is Ask, Allow, or Deny (default Allow). Clipboard read still asks first. The confirmation dialog has Always Allow.

## [0.1.51]

- Agents that were running when Yeet quit — Claude Code, Codex, Grok, OpenCode, Gemini — relaunch with their previous conversation. Turn on AI support so the integration hooks can report each agent's session; panes without a captured session restore as regular terminals. "Resume agents on relaunch" in Settings controls the behavior.
- Coding-agent CLIs such as Claude and Grok no longer stall the window while they stream. The terminal follows a ProMotion display up to 120 Hz.
- `yeet +pane read` returns the live prompt on a fresh terminal, not empty lines from the bottom of the grid.
- The Dock and Finder app icon fills the macOS squircle instead of sitting inset on a gray plate.
- Large files in the editor, including markdown with code fences, open and scroll without dropped frames.
- Rebrand this repository as Yeet (`Yeet.app`, bundle id `sh.yeet`, settings in `~/.config/yeet`). Leftover `~/.config/kerox` (then older `~/.config/kero`) is copied into `~/.config/yeet` when Yeet has no config yet. The same leftover-then-copy applies to Application Support history. The bundled CLI is `yeet`. Terminals export `YEET_*` variables. The automation skill is `yeet-automation`. Terminal notifications use the Yeet name.
- Drop the project-sidebar Send Feedback button (it opened official Kero Issues).
- Website and docs describe Yeet (not Kero). The app and site send no telemetry or analytics. Changelog Latest is the newest released version.
- GitHub Issues are enabled. Open an issue first for anything larger than a fix.
- Install from source, or use the Homebrew cask / `Yeet.zip` when a GitHub Release includes that asset. Builds are ad-hoc signed; if macOS blocks the app, use System Settings → Privacy & Security → Open Anyway. No Sparkle.
- Closing a project, closing a window, or quitting asks to save or discard unsaved file and diff buffers; Cancel keeps everything open.
- Terminal programs can no longer silently replace the clipboard; clipboard writes ask first, same as clipboard reads.
- The in-app browser and command-clicked terminal links only follow ordinary web addresses (`http`/`https`). Other URL schemes are ignored.
- Kitty graphics no longer load images from files on disk.
- Git branch names that start with `-` are rejected. Switching or creating a branch, syncing, popping a stash, or moving files to Trash asks for confirmation when that would be destructive or the worktree is dirty.
- The Files tree no longer freezes the window while reading the disk, and hiding the inspector no longer resets which folders were expanded.

## [0.1.50]

- Dark chrome uses a solid Codex Dark panel so swapped sidebars match.
- Choose a font family and size for file names in the Files inspector, independently of the project sidebar and the Git/Info panels.

## [0.1.49]

- Swap the project sidebar and the Files/Git/Info inspector from Settings, so the inspector can sit on the left and the project list on the right. ⌘B and ⇧⌘B still toggle those panels.

## [0.1.48]

- Ship this fork as Kerox (`Kerox.app`, bundle id `sh.kerox`, settings in `~/.config/kerox`) so it can sit beside official Kero. Install with `brew tap ttaatoo/kero https://github.com/ttaatoo/kero` then `brew install --cask ttaatoo/kero/kerox`. Upgrade with `brew upgrade --cask ttaatoo/kero/kerox`. This is not `brew install egoist/tap/kero`.
- Settings, alerts, and the in-app CLI talk about Kerox when they mean this app. The bundled command is still `kero`.
- Packaged builds do not check official Kero’s Sparkle feed. Settings hides update controls when there is no feed. Use Homebrew or a new GitHub Release zip.
- Paste into the terminal without a “potentially unsafe paste” warning. Kerox still asks before a program reads the clipboard.
- Global hotkey to summon or hide Kerox from any app, configurable in Settings (default: ⌥Space)
- Terminals identify as Kerox, not Ghostty. Image-aware tools can use the Kitty graphics protocol the Alacritty surface implements.

## [0.1.47]

- Let dictation and other accessibility tools enter text in terminal panes
- Choose a block, bar, or underline terminal cursor, with or without blinking
- Respect the selected System, Light, or Dark appearance when Kero launches
- Stop inferring coding-agent progress from terminal text, preventing false Working, Blocked, and Done states from ordinary terminal output

## [0.1.46]

- Fix new terminal panes failing to start a shell after hours of coding-agent use: the Ghostty backend's screen exports leaked two file descriptors each, exhausting the process descriptor table

## [0.1.45]

- Automate project-scoped panes and coding agents from Kero terminals with guarded `+pane` and `+agent` commands, one-click AI setup, semantic status badges, completion notifications, and attention navigation

## [0.1.44]

- Prevent a rare crash while using the Ctrl-Tab switcher

## [0.1.43]

- Command-click local file paths in the terminal to reveal them in Finder, or Command-right-click paths and URLs to open them in new file or browser tabs and panes
- Alacritty terminal panes now move the mouse pointer the way Ghostty panes do: programs can set shapes with OSC 22, mouse-reporting apps show the arrow, and a terminal reset restores the text cursor

## [0.1.42]

- Drag a tab onto the current tab's content to turn it into a split pane

## [0.1.41]

- Fix diff controls and content sometimes using the wrong appearance when Kero follows the system theme

## [0.1.40]

- Edit live worktree changes directly in the diff view, with remembered Review/Edit and Unified/Split controls plus normal save/discard handling
- Fix modified special keys and application-keypad input in Alacritty terminals, including Shift-Enter for multiline prompts in Claude Code
- Fix: Show a green Clean status for unchanged repositories and include untracked files in the toolbar's added-line count
- Clicking a terminal notification activates Kero and jumps to the session that posted it
- Fix desktop notifications from Grok and other OSC 777 clients when using the Alacritty terminal backend
- Close all open files or diffs from the tab bar context menu
- Improve the Recent Commits view in git panel
- Show filename-aware Material icons across file trees, Git file lists, tabs, panes, previews, and file search

## [0.1.39]

- Show the active Git branch and aggregate added/deleted line counts in a toolbar below the active tab, with searchable branch switching, quick access to changed-file diffs, and a setting to show or hide the toolbar (hidden by default)
- Register sound for terminal notifications so System Settings shows Play sound and alerts can chime, including for installs that already allowed notifications

## [0.1.38]

- Terminal notifications play the system sound
- Browser tabs now use a modern Safari user agent, fixing sites such as Bilibili that otherwise report an outdated browser

## [0.1.37]

- Keep the left sidebar toggle available in the main header while the sidebar is hidden
- Adjust sidebar project typography scaling

## [0.1.36]

- The Files panel now shows repository status with colored filenames and badges, including dimmed Git-ignored files
- Switch directly to tabs with Ctrl+1–9, without also holding Shift

## [0.1.35]

- Add per-pane live titles and split controls in split layouts
- Splitting a pane now divides only the focused pane, preserving the size of neighboring panes in nested layouts
- The Ctrl-Tab switcher now lists tabs in the order you last used them and opens already pointing at the previous tab, so a quick Ctrl-Tab flips between the two tabs you're working in

## [0.1.34]

- Show terminal titles verbatim while keeping sidebar project rows stable as titles update or hover controls appear
- Follow the terminal's foreground job into another checkout: when an agent
  switches to its own git worktree, Files, Git and Info re-root to it
- Settings font preview now reflects “Thicken font strokes”
- Prevent terminal tabs from crashing after switching sessions or resizing during a partial redraw
- Files created in a terminal now use your system's default permissions instead of being made private to your user

## [0.1.33]

- Fix: never set `LANG` env for the terminal session

## [0.1.32]

- Add native English, Simplified Chinese, and Japanese localization throughout the app, with a language picker in Settings
- Search and open files from the project directory in the command palette
- Open native browser tabs and split panes from the command palette or terminal/editor context menus, with a combined address/search field, navigation controls, page sharing, and restored URLs

## [0.1.31]

- File previews now refresh after files are changed outside Kero
- Option-key characters from macOS input sources such as Polish Pro now work in terminals; users who prefer terminal Meta bindings can opt in under Settings → Terminal

## [0.1.30]

- Fix Chinese IME under Alacritty backend
- Reduce hidden Ghostty tab renderer memory

## [0.1.29]

- Add `kero` command: run `kero` in any Kero terminal to create a project in the current directory, optionally with an argv to run directly (`kero vim ~/foo.js`); `kero +themes` browses themes with a live app-wide preview and saves the selection on Return
- The Git panel now refreshes after commands and when Kero regains focus instead of polling continuously in the background

## [0.1.28]

- Tweak some UI colors

## [0.1.27]

- Choose which terminal emulator drives new panes in Settings → Terminal → Backend. Ghostty remains the default, with a new Alacritty backend
- Configure the left and right sidebar font size in Settings

## [0.1.26]

- Opening the Ctrl-Tab switcher no longer highlights whichever tab happens to be under the stationary pointer
- The Processes list no longer shows `<defunct>` entries: those are exited children waiting to be reaped, not something you can see output from or kill
- Opening a large diff no longer freezes the window: diffs render only the rows on screen and highlight them off the main thread
- The font setting now applies to the diff viewer too, so diffs match the terminal and the editor
- Sessions you never open no longer cost any GPU memory. Reopening a window used to draw every restored session straight away, holding a full-size buffer for each whether you looked at it or not; now a pane claims one only when you first view it, and claims one buffer less than before. A pane you have already viewed keeps its buffer until you close it — switching away stops it drawing, but does not hand the memory back.

## [0.1.25]

- Add a tab switcher (ctrl-tab) to switch between tabs
- Add audio input support for CLIs that might need it

## [0.1.24]

- set TERM_PROGRAM to ghostty to get image rendering support

## [0.1.23]

- Fix pasting clipboard images into image-aware TUIs such as Grok, and paste Finder-copied files as shell-safe absolute paths (#20)

## [0.1.22]

- Add “Open in Kero” to Finder’s folder context menu, opening each selected folder as a project with its terminal started there
- Full-screen programs with their own background color (vim, htop, TUIs) now fill the terminal pane: the padding around the grid takes on the adjacent content's background instead of always showing the theme background, leaving only a hairline frame at the pane edges
- Fix non-ASCII rendering in git diff view
- Allow to rename session tabs

## [0.1.21]

- Anchor the file tree and Git panel to the project directory — the closest git repository containing the terminal's directory — so they no longer re-root every time you `cd` inside a repo; outside a repository they keep following the terminal as before
- Add "Set Project Directory…" to the project's context menu to pin a fixed directory for these panels ("Use Automatic Directory" reverts); the pin is remembered across relaunches
- Info panel: the Directory section is now split into Current Directory (the shell's live cwd, shown when it differs) and Project Directory, marked "(AUTO)" while derived automatically, with a "?" popover explaining both modes
- Remember sidebar layout across relaunches: each window restores whether the left and right sidebars were open and which right panel (Files/Git/Info) was selected

## [0.1.20]

- Security: stop terminal programs from silently reading your clipboard — an OSC 52 escape sequence (for example from a remote SSH host) could previously read the macOS clipboard without any prompt; kero now asks for confirmation first, matching the Ghostty app default (#8)
- Warn before pasting text that looks like it could execute commands, matching Ghostty's paste protection
- Add color themes: Settings → Colors picks a theme per appearance — kero's Default Light/Dark plus all 485 bundled Ghostty themes — recoloring the terminal, window chrome, sidebars, and editor live. The built-in Defaults keep the GitHub palette and translucent sidebar; every other theme colors the sidebar too
- Fix fuzzy-looking terminal text: font thickening was unintentionally always on, making glyphs heavier and softer than stock Ghostty
- Add a "Thicken font strokes" toggle in Settings → Font for those who prefer the heavier rendering

## [0.1.19]

- Fix a releasing signing issue

## [0.1.18]

- Fix max height of settings window

## [0.1.17]

- Add pane zoom: ⇧⌘↩ toggles the focused pane filling the tab, with a header button indicating the state and exiting zoom
- Add shortcuts to cycle pane focus (⌘[ / ⌘]), resize panes (⌃⌘ arrows) and equalize panes (⌃⌘=)

## [0.1.16]

- Tweaks shortcut description for toggling right sidebar

## [0.1.15]

- Fix potential memory leak

## [0.1.14]

- Add theme setting to force light or dark theme

## [0.1.13]

- Make editor full height
- Tweaks sidebar

## [0.1.12]

- Fix TSX highlight

## [0.1.10]

- fix git panel

## [0.1.9]

- Fix CPU usage spike due to libghostty intergration bug

## [0.1.8]

- Use libghostty

## [0.1.7]

- Remove GPU rendering temporarily

## [0.1.6]

- Fix window maximizing
- Shortcut for left sidebar: cmd-b

## [0.1.5]

- Double-click the title bar to zoom the window (honors the system "double-click a window's title bar to" setting)
- fix gpu rendering

## [0.1.4]

- Add "Session Contents Restored" divider to restored terminals
- set TERM_PROGRAM to Kero
- fix embedded language highlighting in markdown

## [0.1]

### Added
- Initial release.
