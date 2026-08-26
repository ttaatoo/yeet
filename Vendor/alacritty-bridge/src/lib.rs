//! C ABI over `alacritty_terminal` for Kero's Alacritty backend.
//!
//! `alacritty_terminal` is emulation only — VT parser, grid, PTY, selection —
//! with no renderer of any kind. This crate owns the terminal state and the
//! PTY read loop, and hands Swift a flat snapshot of the visible grid to draw
//! with a Metal renderer backed by a CoreText glyph atlas. Everything that
//! would need a reply written back to the PTY (DSR, color queries, text-area
//! size) is answered here rather than crossing the boundary twice.
//!
//! Threading: the PTY read loop runs on its own thread and mutates the
//! terminal behind a `FairMutex`. Render and state-changing entry points try to
//! take that lock; `kero_alacritty_begin_frame` reports BUSY when it is held.
//! The input-path mode getter reads an atomic parser snapshot. The snapshot
//! buffer is owned by the handle and is only valid until the next call on it.

mod graphics_event_loop;
mod kitty_graphics;
mod kitty_graphics_tracking;

use std::borrow::Cow;
use std::collections::VecDeque;
use std::ffi::{c_char, c_void, CStr};
use std::fs::File;
use std::io::{self, Read};
use std::os::fd::{AsRawFd, RawFd};
use std::path::PathBuf;
use std::sync::{
    atomic::{AtomicU32, Ordering},
    Arc, OnceLock,
};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use alacritty_terminal::event::{Event, EventListener, Notify, OnResize, WindowSize};
use alacritty_terminal::grid::{BidirectionalIterator, Dimensions, Scroll};
use alacritty_terminal::index::Direction;
use alacritty_terminal::index::{Boundary, Column, Line, Point, Side};
use alacritty_terminal::selection::{Selection, SelectionRange, SelectionType};
use alacritty_terminal::sync::FairMutex;
use alacritty_terminal::term::cell::{Cell, Flags};
use alacritty_terminal::term::color::Colors;
use alacritty_terminal::term::search::{Match, RegexIter, RegexSearch};
use alacritty_terminal::term::{Config, Osc52, RenderableContent, Term, TermDamage, TermMode};
use alacritty_terminal::tty::{self, EventedPty, EventedReadWrite};
use alacritty_terminal::vte::ansi::{Color, CursorShape, CursorStyle, NamedColor, Rgb};
use polling::{Event as PollingEvent, PollMode, Poller};

use graphics_event_loop::{
    apply_find_message, FindMessage, FindResultStore, FindState, FrameHandoff, GraphicsEventLoop,
    GraphicsEventLoopSender, GraphicsMsg, GraphicsNotifier,
};
use kitty_graphics::{KittyGraphicsScreen, KittyGraphicsSize, KittyGraphicsStore};

// MARK: - C types

/// Event kinds pushed to Swift from the PTY thread. Swift bounces these onto
/// the main thread before touching any view state.
pub const KERO_EVENT_WAKEUP: u32 = 0;
pub const KERO_EVENT_TITLE: u32 = 1;
pub const KERO_EVENT_BELL: u32 = 2;
pub const KERO_EVENT_EXIT: u32 = 3;
pub const KERO_EVENT_CLIPBOARD_STORE: u32 = 4;
pub const KERO_EVENT_CLIPBOARD_LOAD: u32 = 5;
pub const KERO_EVENT_WORKING_DIRECTORY: u32 = 6;
pub const KERO_EVENT_PROGRESS: u32 = 7;
pub const KERO_EVENT_NOTIFICATION: u32 = 8;
pub const KERO_EVENT_SHELL_PROMPT_START: u32 = 9;
pub const KERO_EVENT_SHELL_COMMAND_START: u32 = 10;
pub const KERO_EVENT_SHELL_COMMAND_EXECUTING: u32 = 11;
pub const KERO_EVENT_SHELL_COMMAND_FINISHED: u32 = 12;
pub const KERO_EVENT_MOUSE_SHAPE: u32 = 13;

/// Result kinds published by the asynchronous find worker.
pub const KERO_FIND_RESULT_BEGIN: u32 = 1;
pub const KERO_FIND_RESULT_STEP: u32 = 2;
pub const KERO_FIND_RESULT_END: u32 = 3;
/// The active Find was invalidated by terminal content or geometry changes.
pub const KERO_FIND_RESULT_INVALIDATED: u32 = 4;

/// Tri-state selection query results. BUSY is distinct from an acquired empty
/// selection so UI commands can retry without disabling themselves.
pub const KERO_SELECTION_BUSY: u32 = 0;
pub const KERO_SELECTION_EMPTY: u32 = 1;
pub const KERO_SELECTION_PRESENT: u32 = 2;

/// Per-cell attributes handed to the renderer. A subset of
/// `alacritty_terminal`'s `Flags` plus Kero's own `SELECTED`.
pub const KERO_CELL_INVERSE: u16 = 1 << 0;
pub const KERO_CELL_BOLD: u16 = 1 << 1;
pub const KERO_CELL_ITALIC: u16 = 1 << 2;
pub const KERO_CELL_UNDERLINE: u16 = 1 << 3;
pub const KERO_CELL_STRIKEOUT: u16 = 1 << 4;
pub const KERO_CELL_DIM: u16 = 1 << 5;
pub const KERO_CELL_HIDDEN: u16 = 1 << 6;
pub const KERO_CELL_WIDE: u16 = 1 << 7;
pub const KERO_CELL_WIDE_SPACER: u16 = 1 << 8;
pub const KERO_CELL_SELECTED: u16 = 1 << 9;

/// Nothing changed; the host can drop the frame entirely.
pub const KERO_DAMAGE_NONE: u32 = 0;
/// Only the listed rows changed.
pub const KERO_DAMAGE_PARTIAL: u32 = 1;
/// Everything changed — a resize, a screen swap, a scroll.
pub const KERO_DAMAGE_FULL: u32 = 2;

/// Per-frame verdicts from `kero_alacritty_begin_frame`.
pub const KERO_FRAME_SKIP: u32 = 0;
pub const KERO_FRAME_CURSOR: u32 = 1;
pub const KERO_FRAME_DIRTY: u32 = 2;
pub const KERO_FRAME_FULL: u32 = 3;
/// The terminal or Kitty graphics mutex was busy; the host must retry next frame.
pub const KERO_FRAME_BUSY: u32 = 4;

/// Non-blocking find result read by the host after a worker wakeup.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct KeroFindResult {
    pub generation: u64,
    pub kind: u32,
    pub total: usize,
    pub selected: isize,
}

/// One frame's worth of state: what kind of redraw the host owes, which
/// viewport rows changed, and the snapshots to draw. Everything except
/// `snapshot` and `kitty` is valid until the next call on the handle; their
/// buffers follow the ownership rules of their respective snapshot types.
#[repr(C)]
pub struct KeroFrame {
    /// `KERO_FRAME_*`. The snapshots are filled for CURSOR, DIRTY, and FULL;
    /// SKIP and BUSY leave the previous snapshots untouched.
    pub kind: u32,
    /// Viewport rows that changed, owned by the handle. Empty unless DIRTY.
    pub dirty_rows: *const usize,
    pub dirty_rows_len: usize,
    /// Cumulative number of frame attempts that found a frame lock busy.
    pub busy_count: u64,
    /// Time spent attempting both non-blocking frame locks, in nanoseconds.
    pub lock_wait_ns: u64,
    /// Time spent collecting damage and terminal metadata, in nanoseconds.
    pub snapshot_ns: u64,
    /// Time spent packing rows after metadata collection, in nanoseconds.
    pub build_ns: u64,
    /// Number of rows actually packed during this frame.
    pub packed_rows: usize,
    pub snapshot: KeroSnapshot,
    pub kitty: KeroKittySnapshot,
}

pub type KeroEventCallback =
    extern "C" fn(context: *mut c_void, kind: u32, data: *const u8, len: usize);

#[repr(C)]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct KeroCell {
    /// Unicode scalar; a space for an empty cell.
    pub ch: u32,
    /// Packed 0x00RRGGBB, already resolved through the palette and any OSC 4
    /// overrides — the renderer never resolves colors itself.
    pub fg: u32,
    pub bg: u32,
    /// UTF-8 text in `KeroSnapshot::text` when this cell has combining marks.
    pub text_offset: u32,
    pub text_len: u16,
    pub flags: u16,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct KeroURLRange {
    /// Inclusive viewport-relative cell bounds. Lines can be outside the
    /// viewport when a soft-wrapped URL begins or ends in scrollback.
    pub start_line: i32,
    pub start_column: usize,
    pub end_line: i32,
    pub end_column: usize,
}

/// A theme in the form the bridge resolves colors against. Kero owns the
/// palette so Alacritty panes match Ghostty panes exactly.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct KeroTheme {
    pub palette: [u32; 256],
    pub foreground: u32,
    pub background: u32,
    pub cursor: u32,
}

#[repr(C)]
pub struct KeroSnapshot {
    /// `columns * rows` cells in row-major order, owned by the handle and
    /// valid only until the next call on it.
    pub cells: *const KeroCell,
    pub columns: usize,
    pub rows: usize,
    /// Viewport-relative cursor, or -1 when it should not be drawn.
    pub cursor_line: isize,
    pub cursor_column: isize,
    pub cursor_shape: u32,
    pub cursor_color: u32,
    pub background: u32,
    pub cursor_blinking: bool,
    /// UTF-8 backing for cells whose `text_len` is non-zero.
    pub text: *const u8,
    pub text_len: usize,
    /// Rows scrolled back from the live prompt, and the total including
    /// scrollback — together these drive Kero's overlay scrollbar.
    pub display_offset: usize,
    pub total_lines: usize,
    pub screen_lines: usize,
    /// Stable identity of each viewport row (`rows` entries): the absolute
    /// line index counted from the oldest retained line. Lets the renderer
    /// keep its row-instance cache across a scroll, where only the rows whose
    /// id changed need rebuilding. Valid under the same rules as `cells`.
    pub row_ids: *const u64,
    /// Bumped whenever retained lines are dropped or re-indexed (history trim
    /// at the scrollback cap, resize) or packing inputs change (theme). A
    /// renderer holding cached rows from another generation must discard
    /// them: the same id no longer names the same content.
    pub row_generation: u64,
    /// Viewport-relative text-input anchor, or -1 when the live cursor is not
    /// in the active viewport. Unlike `cursor_line`/`cursor_column`, this
    /// remains populated when the terminal hides its rendering cursor.
    pub ime_cursor_line: isize,
    pub ime_cursor_column: isize,
}

/// Packed-row reuse across frames, keyed by absolute line index so that a
/// display_offset change — which the emulator always reports as full damage —
/// repacks only the rows newly revealed by the scroll.
///
/// Absolute indices count from the oldest retained line, so growth at the
/// bottom never re-indexes existing rows. Everything that can change a row
/// without moving its id is checked under the same term lock the pack runs
/// under, so there is no cross-thread signal to race with: a shrinking
/// `total_lines` (clear, screen swap), a parser damage report, a different
/// selection, or a column change all invalidate the affected rows or bump
/// `generation`. `set_theme` bumps it too.
#[derive(Default)]
struct SnapshotCache {
    rows: std::collections::HashMap<usize, Vec<KeroCell>>,
    generation: u64,
    last_total_lines: usize,
    columns: usize,
    selection: Option<(Point, Point)>,
    /// `viewport_first` of the last completed fill. Cursor-only requests are
    /// upgraded to a full assembly when it moves.
    last_viewport_first: usize,
    /// Per-frame viewport row ids, handed to Swift through `KeroSnapshot`.
    row_ids: Vec<u64>,
}

impl SnapshotCache {
    fn new() -> Self {
        Self {
            last_viewport_first: usize::MAX,
            ..Self::default()
        }
    }
}

/// Combining-text arena bound between full walks. Appends only grow; this
/// converts sustained growth into one full repack instead of a leak.
const CELL_TEXT_LIMIT: usize = 4 << 20;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct KeroKittyPlacement {
    pub placement_serial: u64,
    pub image_id: u32,
    pub placement_id: u32,
    /// 8-bit RGBA, retained by the terminal handle until its next FFI call.
    pub pixels: *const u8,
    pub pixels_len: usize,
    pub image_width: u32,
    pub image_height: u32,
    pub image_generation: u64,
    pub viewport_row: i32,
    pub column: usize,
    pub source_x: u32,
    pub source_y: u32,
    pub source_width: u32,
    pub source_height: u32,
    pub display_columns: u32,
    pub display_rows: u32,
    pub occupied_columns: u32,
    pub occupied_rows: u32,
    pub x_offset: u32,
    pub y_offset: u32,
    pub z_index: i32,
}

#[repr(C)]
pub struct KeroKittySnapshot {
    pub revision: u64,
    pub placements: *const KeroKittyPlacement,
    pub placements_len: usize,
}

#[repr(C)]
pub struct KeroConfig {
    /// Shell to exec, and its argv beyond argv[0].
    pub shell: *const c_char,
    pub args: *const *const c_char,
    pub args_len: usize,
    pub working_directory: *const c_char,
    /// `KEY=VALUE` pairs.
    pub env: *const *const c_char,
    pub env_len: usize,
    pub columns: u16,
    pub rows: u16,
    pub cell_width: u16,
    pub cell_height: u16,
    pub scrollback_lines: usize,
    /// 0 block, 1 underline, 2 beam.
    pub cursor_shape: u8,
    pub cursor_blinking: bool,
}

fn configured_cursor_style(shape: u8, blinking: bool) -> CursorStyle {
    CursorStyle {
        shape: match shape {
            1 => CursorShape::Underline,
            2 => CursorShape::Beam,
            _ => CursorShape::Block,
        },
        blinking,
    }
}

// MARK: - OSC interception

/// `alacritty_terminal` handles OSC sequences that mutate its grid, but does
/// not expose host events for working directories or desktop notifications.
/// Termy solves this at the PTY boundary; Kero uses the same integration point so the
/// emulator still receives every sequence it understands while app
/// integrations are lifted out first.
#[derive(Debug, Clone, PartialEq, Eq)]
enum OscEvent {
    WorkingDirectory(String),
    Progress { state: u8, percent: Option<u8> },
    Notification(String),
    ShellPromptStart,
    ShellCommandStart,
    ShellCommandExecuting,
    ShellCommandFinished(Option<i32>),
    MouseShape(String),
}

#[derive(Debug, Default)]
struct OscInterceptor {
    state: OscParseState,
    buffer: Vec<u8>,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
enum OscParseState {
    #[default]
    Ground,
    Escape,
    Start,
    Payload,
    PayloadEscape,
}

/// Terminal output is untrusted and an unterminated OSC must not grow forever.
const MAX_OSC_BYTES: usize = 64 * 1024;

impl OscInterceptor {
    fn process<'a>(&mut self, input: &'a [u8]) -> (Cow<'a, [u8]>, Vec<OscEvent>) {
        if self.state == OscParseState::Ground
            && input.last() != Some(&0x1b)
            && !input.windows(2).any(|pair| pair == b"\x1b]")
        {
            return (Cow::Borrowed(input), Vec::new());
        }

        let mut output = Vec::with_capacity(input.len());
        let mut events = Vec::new();

        for &byte in input {
            match self.state {
                OscParseState::Ground => {
                    if byte == 0x1b {
                        self.state = OscParseState::Escape;
                    } else {
                        output.push(byte);
                    }
                }
                OscParseState::Escape => {
                    if byte == b']' {
                        self.buffer.clear();
                        self.state = OscParseState::Start;
                    } else {
                        output.extend_from_slice(&[0x1b, byte]);
                        self.state = OscParseState::Ground;
                    }
                }
                OscParseState::Start => {
                    self.buffer.push(byte);
                    self.state = OscParseState::Payload;
                }
                OscParseState::Payload => {
                    if byte == 0x07 {
                        self.finish(&mut output, &mut events);
                    } else if byte == 0x1b {
                        self.state = OscParseState::PayloadEscape;
                    } else if self.buffer.len() < MAX_OSC_BYTES {
                        self.buffer.push(byte);
                    } else {
                        self.emit_passthrough(&mut output);
                        self.reset();
                    }
                }
                OscParseState::PayloadEscape => {
                    if byte == b'\\' {
                        self.finish(&mut output, &mut events);
                    } else if self.buffer.len() + 2 <= MAX_OSC_BYTES {
                        self.buffer.extend_from_slice(&[0x1b, byte]);
                        self.state = OscParseState::Payload;
                    } else {
                        self.emit_passthrough(&mut output);
                        self.reset();
                    }
                }
            }
        }

        (Cow::Owned(output), events)
    }

    fn finish(&mut self, output: &mut Vec<u8>, events: &mut Vec<OscEvent>) {
        if let Some(event) = self.parse_payload() {
            events.push(event);
        } else if !self.should_consume_payload() {
            // Alacritty still needs titles, colors, OSC 8 links, OSC 52, and
            // every other sequence it already implements.
            self.emit_passthrough(output);
        }
        self.reset();
    }

    fn reset(&mut self) {
        self.buffer.clear();
        self.state = OscParseState::Ground;
    }

    /// BEL and ST are equivalent OSC terminators. Normalizing passthrough to
    /// BEL avoids retaining another bit of parser state.
    fn emit_passthrough(&self, output: &mut Vec<u8>) {
        output.extend_from_slice(b"\x1b]");
        output.extend_from_slice(&self.buffer);
        output.push(0x07);
    }

    fn should_consume_payload(&self) -> bool {
        std::str::from_utf8(&self.buffer).is_ok_and(|payload| {
            payload.starts_with("7;")
                || payload.starts_with("9;")
                || payload.starts_with("22;")
                || payload.starts_with("777;notify;")
        })
    }

    fn parse_payload(&self) -> Option<OscEvent> {
        let payload = std::str::from_utf8(&self.buffer).ok()?;

        if let Some(url) = payload.strip_prefix("7;") {
            return working_directory_from_osc7(url).map(OscEvent::WorkingDirectory);
        }

        if let Some(name) = payload.strip_prefix("22;") {
            // OSC 22 pointer shape. Like Ghostty, Kero takes a single CSS
            // cursor keyword and no kitty push/pop stack; the host owns the
            // keyword list, so the name crosses as-is and typos die there.
            return clean_terminal_text(name, 64).map(OscEvent::MouseShape);
        }

        if let Some(value) = payload.strip_prefix("133;") {
            return parse_shell_integration(value);
        }

        if let Some(value) = payload.strip_prefix("777;notify;") {
            return parse_osc777_notification(value);
        }

        let rest = payload.strip_prefix("9;")?;
        if let Some(progress) = rest.strip_prefix("4;") {
            return parse_progress(progress);
        }
        if let Some(path) = rest.strip_prefix("9;") {
            return clean_terminal_text(path.trim().trim_matches('"'), 4096)
                .map(OscEvent::WorkingDirectory);
        }

        clean_terminal_text(rest, 4096).map(OscEvent::Notification)
    }
}

// MARK: - Escape-stream scanning

/// Watches the raw stream for escape sequences the host must react to but
/// `alacritty_terminal` will not report. DEC private mode 2026: Alacritty
/// buffers the enclosed bytes atomically, but Kero's host-driven cursor timer
/// can otherwise request a frame while that buffer is still being assembled.
/// Pointer shape: Ghostty's stream handler moves the pointer when mouse
/// reporting toggles and when RIS lands, and the emulator reports neither.
#[derive(Debug, Default)]
struct StreamScanner {
    state: ScanState,
    parameters: Vec<u8>,
}

const MODE_APP_CURSOR: u32 = 1 << 0;
const MODE_APP_KEYPAD: u32 = 1 << 1;
const MODE_ALT_SCREEN: u32 = 1 << 2;
const MODE_BRACKETED_PASTE: u32 = 1 << 3;
const MODE_MOUSE: u32 = 1 << 4;
const MODE_FOCUS_IN_OUT: u32 = 1 << 5;
const MODE_MOUSE_REPORT_CLICK: u32 = 1 << 6;
const MODE_MOUSE_DRAG: u32 = 1 << 7;
const MODE_MOUSE_MOTION: u32 = 1 << 8;
const MODE_SGR_MOUSE: u32 = 1 << 9;
const MODE_ALTERNATE_SCROLL: u32 = 1 << 10;

/// Last terminal mode published by the stream parser. The input path reads
/// this atomic snapshot instead of waiting for the terminal mutex.
#[derive(Clone)]
struct ModeSnapshot(Arc<AtomicU32>);

impl ModeSnapshot {
    fn new() -> Self {
        Self(Arc::new(AtomicU32::new(0)))
    }

    fn load(&self) -> u32 {
        self.0.load(Ordering::Acquire)
    }

    pub(crate) fn store_term_mode(&self, mode: TermMode) {
        self.0.store(mode_bits(mode), Ordering::Release);
    }
}

pub(crate) fn mode_bits(mode: TermMode) -> u32 {
    let mut result = 0u32;
    if mode.contains(TermMode::APP_CURSOR) {
        result |= MODE_APP_CURSOR;
    }
    if mode.contains(TermMode::APP_KEYPAD) {
        result |= MODE_APP_KEYPAD;
    }
    if mode.contains(TermMode::ALT_SCREEN) {
        result |= MODE_ALT_SCREEN;
    }
    if mode.contains(TermMode::BRACKETED_PASTE) {
        result |= MODE_BRACKETED_PASTE;
    }
    if mode.intersects(TermMode::MOUSE_MODE) {
        result |= MODE_MOUSE;
    }
    if mode.contains(TermMode::FOCUS_IN_OUT) {
        result |= MODE_FOCUS_IN_OUT;
    }
    if mode.contains(TermMode::MOUSE_REPORT_CLICK) {
        result |= MODE_MOUSE_REPORT_CLICK;
    }
    if mode.contains(TermMode::MOUSE_DRAG) {
        result |= MODE_MOUSE_DRAG;
    }
    if mode.contains(TermMode::MOUSE_MOTION) {
        result |= MODE_MOUSE_MOTION;
    }
    if mode.contains(TermMode::SGR_MOUSE) {
        result |= MODE_SGR_MOUSE;
    }
    if mode.contains(TermMode::ALTERNATE_SCROLL) {
        result |= MODE_ALTERNATE_SCROLL;
    }
    result
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
enum ScanState {
    #[default]
    Ground,
    Escape,
    Csi,
    ControlString,
    ControlStringEscape,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SyncUpdateEvent {
    Start,
    End,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ScanEvent {
    SyncUpdate(SyncUpdateEvent),
    /// A pointer-shape name for the host, coupled exactly as Ghostty's stream
    /// handler couples them: enabling any mouse-reporting mode shows
    /// `default`, disabling one restores `text`, and RIS restores `text`.
    MouseShape(&'static str),
}

const SYNCHRONIZED_UPDATE_TIMEOUT: Duration = Duration::from_millis(150);

/// Alacritty's default URL hint plus local file paths containing a slash.
/// Requiring a slash avoids turning ordinary dotted words into links while
/// still covering absolute, home-relative, explicit-relative, and project-
/// relative paths.
#[rustfmt::skip]
const LINK_REGEX: &str = "((ipfs:|ipns:|magnet:|mailto:|gemini://|gopher://|https://|http://|news:|file:|git://|ssh:|ftp://)|\
                          (/|~/|\\./|\\.\\./|[A-Za-z0-9._@%+~-]+/))\
                         [^\u{0000}-\u{001F}\u{007F}-\u{009F}<>\"\\s{-}\\^⟨⟩`\\\\]+";

/// Avoid walking an effectively unbounded soft-wrapped logical line on hover.
const MAX_URL_SEARCH_LINES: i32 = 100;

impl StreamScanner {
    fn process(&mut self, input: &[u8]) -> Vec<ScanEvent> {
        let mut events = Vec::new();

        for &byte in input {
            match self.state {
                ScanState::Ground => match byte {
                    0x1b => self.state = ScanState::Escape,
                    0x9b => self.start_csi(),
                    0x90 | 0x98 | 0x9d | 0x9e | 0x9f => self.state = ScanState::ControlString,
                    _ => {}
                },
                ScanState::Escape => match byte {
                    b'[' => self.start_csi(),
                    b']' | b'P' | b'X' | b'^' | b'_' => self.state = ScanState::ControlString,
                    // RIS. Bare `ESC c` only: a preceding intermediate byte —
                    // a charset designation like `ESC ( c` — leaves Escape
                    // state before this arm can see the final byte.
                    b'c' => {
                        events.push(ScanEvent::MouseShape("text"));
                        self.state = ScanState::Ground;
                    }
                    0x1b => {}
                    _ => self.state = ScanState::Ground,
                },
                ScanState::Csi => match byte {
                    0x1b => {
                        self.parameters.clear();
                        self.state = ScanState::Escape;
                    }
                    0x40..=0x7e => {
                        self.dispatch_csi(byte, &mut events);
                        self.parameters.clear();
                        self.state = ScanState::Ground;
                    }
                    0x20..=0x3f if self.parameters.len() < 32 => {
                        self.parameters.push(byte);
                    }
                    0x18 | 0x1a => {
                        self.parameters.clear();
                        self.state = ScanState::Ground;
                    }
                    _ => {}
                },
                ScanState::ControlString => match byte {
                    0x07 | 0x9c => self.state = ScanState::Ground,
                    0x1b => self.state = ScanState::ControlStringEscape,
                    _ => {}
                },
                ScanState::ControlStringEscape => match byte {
                    b'\\' | 0x9c => self.state = ScanState::Ground,
                    0x1b => {}
                    _ => self.state = ScanState::ControlString,
                },
            }
        }

        events
    }

    fn start_csi(&mut self) {
        self.parameters.clear();
        self.state = ScanState::Csi;
    }

    /// DECSET/DECRST, one event per recognized mode in the parameter list:
    /// 2026 gates frames, and the mouse-reporting family moves the pointer
    /// shape the way Ghostty's stream handler does.
    fn dispatch_csi(&self, final_byte: u8, events: &mut Vec<ScanEvent>) {
        let enabled = match final_byte {
            b'h' => true,
            b'l' => false,
            _ => return,
        };
        let Some(modes) = self.parameters.strip_prefix(b"?") else {
            return;
        };
        for mode in modes.split(|&byte| byte == b';') {
            match mode {
                b"2026" => events.push(ScanEvent::SyncUpdate(if enabled {
                    SyncUpdateEvent::Start
                } else {
                    SyncUpdateEvent::End
                })),
                b"9" | b"1000" | b"1002" | b"1003" => {
                    events.push(ScanEvent::MouseShape(if enabled {
                        "default"
                    } else {
                        "text"
                    }))
                }
                _ => {}
            }
        }
    }
}

fn working_directory_from_osc7(value: &str) -> Option<String> {
    let path = if let Some(rest) = value.strip_prefix("file://") {
        let slash = rest.find('/')?;
        &rest[slash..]
    } else {
        value
    };
    let decoded = percent_decode(path);
    clean_terminal_text(&decoded, 4096)
}

fn parse_progress(value: &str) -> Option<OscEvent> {
    let mut parts = value.split(';');
    let state = parts.next()?.parse::<u8>().ok()?;
    if state > 4 {
        return None;
    }
    let percent = parts
        .next()
        .and_then(|value| value.parse::<u8>().ok())
        .map(|value| value.min(100));
    Some(OscEvent::Progress { state, percent })
}

/// Rxvt/VTE/Ghostty desktop notifications use
/// `OSC 777 ; notify ; title ; body ST`. Kero presents its own app title, so
/// prefer the body and fall back to the protocol title when no body is sent.
fn parse_osc777_notification(value: &str) -> Option<OscEvent> {
    let (title, body) = value.split_once(';').unwrap_or((value, ""));
    let message = if body.is_empty() { title } else { body };
    clean_terminal_text(message, 4096).map(OscEvent::Notification)
}

/// FinalTerm semantic prompt markers, also emitted by modern shell
/// integrations in Ghostty, iTerm2, VS Code, and Windows Terminal.
fn parse_shell_integration(value: &str) -> Option<OscEvent> {
    let mut fields = value.split(';');
    match fields.next()? {
        "A" => Some(OscEvent::ShellPromptStart),
        "B" => Some(OscEvent::ShellCommandStart),
        "C" => Some(OscEvent::ShellCommandExecuting),
        "D" => {
            let exit_code = fields
                .next()
                .filter(|value| !value.is_empty())
                .and_then(|value| value.parse::<i32>().ok());
            Some(OscEvent::ShellCommandFinished(exit_code))
        }
        _ => None,
    }
}

fn clean_terminal_text(value: &str, max_bytes: usize) -> Option<String> {
    if value.is_empty() || value.chars().any(|character| character.is_control()) {
        return None;
    }
    let end = value
        .char_indices()
        .map(|(index, _)| index)
        .take_while(|index| *index <= max_bytes)
        .last()
        .unwrap_or(0);
    let end = if value.len() <= max_bytes {
        value.len()
    } else if end == 0 {
        return None;
    } else {
        end
    };
    Some(value[..end].to_owned())
}

fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            if let (Some(high), Some(low)) =
                (hex_value(bytes[index + 1]), hex_value(bytes[index + 2]))
            {
                decoded.push((high << 4) | low);
                index += 3;
                continue;
            }
        }
        decoded.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&decoded).into_owned()
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

// MARK: - Event proxy

/// Swift's view pointer, carried to the PTY thread. Kero keeps the pointer
/// alive for as long as the handle exists, and every callback is bounced onto
/// the main thread on the Swift side before it touches anything.
#[derive(Clone, Copy)]
struct SwiftContext(*mut c_void);
unsafe impl Send for SwiftContext {}
unsafe impl Sync for SwiftContext {}

/// State the PTY thread needs in order to answer queries without calling into
/// Swift: the palette for color reports, and the geometry for size reports.
/// Per terminal, since Kero runs many panes at different sizes.
struct Shared {
    theme: KeroTheme,
    window_size: WindowSize,
    synchronized_update: bool,
    synchronized_update_ending: bool,
    synchronized_update_deadline: Option<Instant>,
    /// OSC 52 read formatters waiting for Kero's confirmation sheet. Keeping
    /// the formatter here preserves whether the request used BEL or ST.
    pending_clipboard: VecDeque<(u64, Arc<dyn Fn(&str) -> String + Sync + Send + 'static>)>,
    next_clipboard_id: u64,
}

#[derive(Clone)]
struct Proxy {
    callback: KeroEventCallback,
    context: SwiftContext,
    /// Filled once the event loop exists. Replies that the terminal generates
    /// on its own (DSR, color and size queries) are written straight back here
    /// instead of crossing into Swift and back.
    sender: Arc<OnceLock<GraphicsEventLoopSender>>,
    shared: Arc<FairMutex<Shared>>,
}

impl Proxy {
    fn emit(&self, kind: u32, payload: &[u8]) {
        (self.callback)(self.context.0, kind, payload.as_ptr(), payload.len());
    }

    fn write_pty(&self, text: String) {
        if let Some(sender) = self.sender.get() {
            let _ = sender.send(GraphicsMsg::Input(text.into_bytes().into()));
        }
    }

    fn record_synchronized_update(&self, event: SyncUpdateEvent) {
        let mut shared = self.shared.lock();
        match event {
            SyncUpdateEvent::Start => {
                shared.synchronized_update = true;
                shared.synchronized_update_ending = false;
                shared.synchronized_update_deadline =
                    Some(Instant::now() + SYNCHRONIZED_UPDATE_TIMEOUT);
            }
            SyncUpdateEvent::End if shared.synchronized_update => {
                // The reader sees ESU before Alacritty has parsed the bytes.
                // Keep suppression active until its Wakeup confirms the
                // buffered frame has been committed.
                shared.synchronized_update_ending = true;
            }
            SyncUpdateEvent::End => {}
        }
    }

    fn finish_synchronized_update_if_ready(&self) {
        let mut shared = self.shared.lock();
        let timed_out = shared
            .synchronized_update_deadline
            .is_some_and(|deadline| deadline <= Instant::now());
        if shared.synchronized_update && (shared.synchronized_update_ending || timed_out) {
            shared.synchronized_update = false;
            shared.synchronized_update_ending = false;
            shared.synchronized_update_deadline = None;
        }
    }

    fn emit_osc(&self, event: OscEvent) {
        match event {
            OscEvent::WorkingDirectory(path) => {
                self.emit(KERO_EVENT_WORKING_DIRECTORY, path.as_bytes())
            }
            OscEvent::Progress { state, percent } => self.emit(
                KERO_EVENT_PROGRESS,
                &[state, percent.unwrap_or(0), u8::from(percent.is_some())],
            ),
            OscEvent::Notification(message) => {
                self.emit(KERO_EVENT_NOTIFICATION, message.as_bytes())
            }
            OscEvent::ShellPromptStart => self.emit(KERO_EVENT_SHELL_PROMPT_START, &[]),
            OscEvent::ShellCommandStart => self.emit(KERO_EVENT_SHELL_COMMAND_START, &[]),
            OscEvent::ShellCommandExecuting => self.emit(KERO_EVENT_SHELL_COMMAND_EXECUTING, &[]),
            OscEvent::ShellCommandFinished(exit_code) => self.emit(
                KERO_EVENT_SHELL_COMMAND_FINISHED,
                &exit_code.unwrap_or(-1).to_le_bytes(),
            ),
            OscEvent::MouseShape(name) => self.emit(KERO_EVENT_MOUSE_SHAPE, name.as_bytes()),
        }
    }
}

/// Reader installed in front of Alacritty's stock event loop. Most reads take
/// the borrowed fast path and return directly from the caller's buffer.
struct OscReader {
    inner: File,
    interceptor: OscInterceptor,
    scanner: StreamScanner,
    pending: VecDeque<u8>,
    proxy: Proxy,
}

impl Read for OscReader {
    fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
        if output.is_empty() {
            return Ok(0);
        }
        if !self.pending.is_empty() {
            return Ok(drain_bytes(&mut self.pending, output));
        }

        let count = self.inner.read(output)?;
        if count == 0 {
            return Ok(0);
        }

        for event in self.scanner.process(&output[..count]) {
            match event {
                ScanEvent::SyncUpdate(sync) => self.proxy.record_synchronized_update(sync),
                // Synthetic OSC 22: the host treats Ghostty's implied shape
                // changes exactly like ones a program asked for by name.
                ScanEvent::MouseShape(name) => {
                    self.proxy.emit_osc(OscEvent::MouseShape(name.to_owned()));
                }
            }
        }

        let (filtered, events) = self.interceptor.process(&output[..count]);
        for event in events {
            self.proxy.emit_osc(event);
        }

        match filtered {
            Cow::Borrowed(_) => Ok(count),
            Cow::Owned(bytes) => {
                let written = bytes.len().min(output.len());
                output[..written].copy_from_slice(&bytes[..written]);
                self.pending.extend(bytes[written..].iter().copied());
                Ok(written)
            }
        }
    }
}

fn drain_bytes(bytes: &mut VecDeque<u8>, output: &mut [u8]) -> usize {
    let count = bytes.len().min(output.len());
    for target in &mut output[..count] {
        *target = bytes.pop_front().expect("count is bounded by queue length");
    }
    count
}

/// Delegates polling, writes, resizes, and child-exit handling to Alacritty's
/// PTY while substituting the OSC-aware reader above.
struct OscPty {
    inner: tty::Pty,
    reader: OscReader,
}

impl OscPty {
    fn new(inner: tty::Pty, proxy: Proxy) -> io::Result<Self> {
        let reader = inner.file().try_clone()?;
        Ok(Self {
            inner,
            reader: OscReader {
                inner: reader,
                interceptor: OscInterceptor::default(),
                scanner: StreamScanner::default(),
                pending: VecDeque::new(),
                proxy,
            },
        })
    }
}

impl EventedReadWrite for OscPty {
    type Reader = OscReader;
    type Writer = File;

    unsafe fn register(
        &mut self,
        poller: &Arc<Poller>,
        interest: PollingEvent,
        mode: PollMode,
    ) -> io::Result<()> {
        unsafe { self.inner.register(poller, interest, mode) }
    }

    fn reregister(
        &mut self,
        poller: &Arc<Poller>,
        interest: PollingEvent,
        mode: PollMode,
    ) -> io::Result<()> {
        self.inner.reregister(poller, interest, mode)
    }

    fn deregister(&mut self, poller: &Arc<Poller>) -> io::Result<()> {
        self.inner.deregister(poller)
    }

    fn reader(&mut self) -> &mut Self::Reader {
        &mut self.reader
    }

    fn writer(&mut self) -> &mut Self::Writer {
        self.inner.writer()
    }
}

impl EventedPty for OscPty {
    fn next_child_event(&mut self) -> Option<tty::ChildEvent> {
        self.inner.next_child_event()
    }
}

impl OnResize for OscPty {
    fn on_resize(&mut self, window_size: WindowSize) {
        self.inner.on_resize(window_size);
    }
}

impl EventListener for Proxy {
    fn send_event(&self, event: Event) {
        match event {
            Event::Wakeup => {
                self.finish_synchronized_update_if_ready();
                self.emit(KERO_EVENT_WAKEUP, &[]);
            }
            Event::Bell => self.emit(KERO_EVENT_BELL, &[]),
            Event::Title(title) => self.emit(KERO_EVENT_TITLE, title.as_bytes()),
            // Kero derives the tab title from the shell and directory, so a
            // reset is the absence of a title.
            Event::ResetTitle => self.emit(KERO_EVENT_TITLE, &[]),
            Event::Exit | Event::ChildExit(_) => self.emit(KERO_EVENT_EXIT, &[]),
            Event::ClipboardStore(_, text) => {
                self.emit(KERO_EVENT_CLIPBOARD_STORE, text.as_bytes())
            }
            Event::ClipboardLoad(_, format) => {
                let id = {
                    let mut shared = self.shared.lock();
                    let id = shared.next_clipboard_id;
                    shared.next_clipboard_id = shared.next_clipboard_id.wrapping_add(1).max(1);
                    // A malicious stream must not retain unbounded formatters
                    // while confirmation sheets are waiting.
                    if shared.pending_clipboard.len() >= 16 {
                        shared.pending_clipboard.pop_front();
                    }
                    shared.pending_clipboard.push_back((id, format));
                    id
                };
                self.emit(KERO_EVENT_CLIPBOARD_LOAD, &id.to_le_bytes());
            }
            Event::PtyWrite(text) => self.write_pty(text),
            Event::ColorRequest(index, format) => {
                let theme = self.shared.lock().theme;
                self.write_pty(format(unpack(color_for_index(index, &theme))));
            }
            Event::TextAreaSizeRequest(format) => {
                let size = self.shared.lock().window_size;
                self.write_pty(format(size));
            }
            Event::MouseCursorDirty | Event::CursorBlinkingChange => {}
        }
    }
}

// MARK: - Handle

struct TermSize {
    columns: usize,
    screen_lines: usize,
}

impl Dimensions for TermSize {
    fn total_lines(&self) -> usize {
        self.screen_lines
    }

    fn screen_lines(&self) -> usize {
        self.screen_lines
    }

    fn columns(&self) -> usize {
        self.columns
    }
}

pub struct KeroTerminal {
    /// The PTY worker owns the terminal and callback proxy after `new` returns.
    /// Keep its join handle so `free` cannot return while that worker can still
    /// emit events or touch any of the shared terminal state.
    event_loop: Option<JoinHandle<()>>,
    term: Arc<FairMutex<Term<Proxy>>>,
    mode_snapshot: ModeSnapshot,
    term_config: Config,
    notifier: GraphicsNotifier,
    shared: Arc<FairMutex<Shared>>,
    kitty_graphics: Arc<FairMutex<KittyGraphicsStore>>,
    kitty_graphics_size: Arc<FairMutex<KittyGraphicsSize>>,
    find_state: Arc<FairMutex<FindState>>,
    find_results: FindResultStore,
    cells: Vec<KeroCell>,
    /// Variable-length UTF-8 cell contents for combining character clusters.
    cell_text: Vec<u8>,
    /// Palette used when packing snapshot cells. Copied on `set_theme` so a
    /// redraw does not take the PTY-shared lock.
    theme: KeroTheme,
    /// Inclusive viewport-relative row span of the last reported selection.
    /// Alacritty's grid damage does not include selection.
    last_selection_rows: Option<(i32, i32)>,
    child_pid: i32,
    /// Kept so the host can ask which process group is in the foreground —
    /// that is how Kero tells a shell at its prompt from a running TUI.
    master_fd: RawFd,
    /// Alacritty's URL hint DFA is reused because this lookup runs on every
    /// mouse move while the pointer is over the terminal.
    url_regex: RegexSearch,
    /// Reused per frame so damage reporting does not allocate.
    dirty_rows: Vec<usize>,
    kitty_placements: Vec<KeroKittyPlacement>,
    /// Retains each placement's RGBA while C pointers are visible to Swift.
    kitty_images: Vec<Arc<[u8]>>,
    last_kitty_damage_revision: u64,
    /// Packed rows reused across frames; see `SnapshotCache`.
    snapshot_cache: SnapshotCache,
    /// Number of non-blocking frame attempts that observed a frame lock busy.
    frame_busy_count: u64,
    /// Coordinates an already-scheduled frame with the PTY parser without
    /// ever blocking the UI thread.
    frame_handoff: FrameHandoff,
    /// Set once the shell has exited, so teardown can skip a redundant shutdown
    /// message. `free` still joins the worker in every case.
    exited: bool,
}

fn pack(rgb: Rgb) -> u32 {
    ((rgb.r as u32) << 16) | ((rgb.g as u32) << 8) | rgb.b as u32
}

fn unpack(value: u32) -> Rgb {
    Rgb {
        r: (value >> 16) as u8,
        g: (value >> 8) as u8,
        b: value as u8,
    }
}

/// Two thirds brightness, matching how terminals conventionally render SGR 2.
fn dim(value: u32) -> u32 {
    let scale = |channel: u32| (channel * 2 / 3) & 0xff;
    (scale((value >> 16) & 0xff) << 16) | (scale((value >> 8) & 0xff) << 8) | scale(value & 0xff)
}

/// Resolves a `Colors` index — which is `NamedColor as usize` — to the theme.
fn color_for_index(index: usize, theme: &KeroTheme) -> u32 {
    match index {
        0..=255 => theme.palette[index],
        i if i == NamedColor::Foreground as usize => theme.foreground,
        i if i == NamedColor::Background as usize => theme.background,
        i if i == NamedColor::Cursor as usize => theme.cursor,
        i if i == NamedColor::BrightForeground as usize => theme.foreground,
        i if i == NamedColor::DimForeground as usize => dim(theme.foreground),
        i if i >= NamedColor::DimBlack as usize && i <= NamedColor::DimWhite as usize => {
            dim(theme.palette[i - NamedColor::DimBlack as usize])
        }
        _ => theme.foreground,
    }
}

/// OSC 4 / OSC 10-11 overrides win over the theme, exactly as they do in
/// Kero's Ghostty panes.
fn resolve(color: Color, colors: &Colors, theme: &KeroTheme) -> u32 {
    match color {
        Color::Spec(rgb) => pack(rgb),
        Color::Indexed(index) => colors[index as usize]
            .map(pack)
            .unwrap_or_else(|| theme.palette[index as usize]),
        Color::Named(named) => {
            let index = named as usize;
            colors[index]
                .map(pack)
                .unwrap_or_else(|| color_for_index(index, theme))
        }
    }
}

unsafe fn cstr(pointer: *const c_char) -> Option<String> {
    if pointer.is_null() {
        return None;
    }
    CStr::from_ptr(pointer).to_str().ok().map(str::to_owned)
}

unsafe fn cstr_array(pointer: *const *const c_char, len: usize) -> Vec<String> {
    if pointer.is_null() {
        return Vec::new();
    }
    (0..len).filter_map(|i| cstr(*pointer.add(i))).collect()
}

// MARK: - Lifecycle

/// Spawns a shell on a new PTY and starts reading it.
///
/// # Safety
/// Every pointer in `config` must be valid for the duration of the call, and
/// `context` must outlive the returned handle.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_new(
    config: *const KeroConfig,
    theme: *const KeroTheme,
    callback: KeroEventCallback,
    context: *mut c_void,
) -> *mut KeroTerminal {
    if config.is_null() || theme.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(url_regex) = RegexSearch::new(LINK_REGEX) else {
        return std::ptr::null_mut();
    };
    let config = &*config;
    let columns = config.columns.max(1) as usize;
    let screen_lines = config.rows.max(1) as usize;

    let window_size = WindowSize {
        num_lines: config.rows.max(1),
        num_cols: config.columns.max(1),
        cell_width: config.cell_width.max(1),
        cell_height: config.cell_height.max(1),
    };

    let shell = cstr(config.shell);
    let args = cstr_array(config.args, config.args_len);
    let mut options = tty::Options {
        shell: shell.map(|program| tty::Shell::new(program, args)),
        working_directory: cstr(config.working_directory).map(PathBuf::from),
        drain_on_exit: false,
        ..Default::default()
    };
    for entry in cstr_array(config.env, config.env_len) {
        if let Some((key, value)) = entry.split_once('=') {
            options.env.insert(key.to_owned(), value.to_owned());
        }
    }

    let shared = Arc::new(FairMutex::new(Shared {
        theme: *theme,
        window_size,
        synchronized_update: false,
        synchronized_update_ending: false,
        synchronized_update_deadline: None,
        pending_clipboard: VecDeque::new(),
        next_clipboard_id: 1,
    }));
    let mode_snapshot = ModeSnapshot::new();
    let proxy = Proxy {
        callback,
        context: SwiftContext(context),
        sender: Arc::new(OnceLock::new()),
        shared: shared.clone(),
    };

    let term_config = Config {
        scrolling_history: config.scrollback_lines.max(1),
        default_cursor_style: configured_cursor_style(config.cursor_shape, config.cursor_blinking),
        // Kero owns clipboard policy at the app level. Reads are enabled in
        // the emulator only so the host can present its confirmation sheet;
        // the bridge writes nothing back until that request is approved.
        osc52: Osc52::CopyPaste,
        ..Default::default()
    };
    let size = TermSize {
        columns,
        screen_lines,
    };
    let term = Arc::new(FairMutex::new(Term::new(
        term_config.clone(),
        &size,
        proxy.clone(),
    )));
    let kitty_graphics = Arc::new(FairMutex::new(KittyGraphicsStore::default()));
    let kitty_graphics_size = Arc::new(FairMutex::new(KittyGraphicsSize {
        columns,
        rows: screen_lines,
        cell_width: f32::from(config.cell_width.max(1)),
        cell_height: f32::from(config.cell_height.max(1)),
    }));
    let find_state = Arc::new(FairMutex::new(FindState::default()));
    let find_results = FindResultStore::new();
    let frame_handoff = FrameHandoff::new();

    let pty = match tty::new(&options, window_size, 0) {
        Ok(pty) => pty,
        Err(_) => return std::ptr::null_mut(),
    };
    let child_pid = pty.child().id() as i32;
    let master_fd = pty.file().as_raw_fd();

    let pty = match OscPty::new(pty, proxy.clone()) {
        Ok(pty) => pty,
        Err(_) => return std::ptr::null_mut(),
    };
    let event_loop = match GraphicsEventLoop::new(
        term.clone(),
        proxy.clone(),
        pty,
        kitty_graphics.clone(),
        kitty_graphics_size.clone(),
        mode_snapshot.clone(),
        find_state.clone(),
        find_results.clone(),
        frame_handoff.clone(),
    ) {
        Ok(event_loop) => event_loop,
        Err(_) => return std::ptr::null_mut(),
    };
    let sender = event_loop.channel();
    // Now that the loop exists, terminal-generated replies have somewhere to go.
    let _ = proxy.sender.set(sender.clone());
    let event_loop = event_loop.spawn();

    Box::into_raw(Box::new(KeroTerminal {
        event_loop: Some(event_loop),
        term,
        mode_snapshot,
        term_config,
        notifier: GraphicsNotifier(sender),
        shared,
        kitty_graphics,
        kitty_graphics_size,
        find_state,
        find_results,
        cells: Vec::new(),
        cell_text: Vec::new(),
        theme: *theme,
        last_selection_rows: None,
        child_pid,
        master_fd,
        url_regex,
        dirty_rows: Vec::new(),
        kitty_placements: Vec::new(),
        kitty_images: Vec::new(),
        last_kitty_damage_revision: 0,
        snapshot_cache: SnapshotCache::new(),
        frame_busy_count: 0,
        frame_handoff,
        exited: false,
    }))
}

/// Stops the read loop and releases the handle.
///
/// # Safety
/// `handle` must come from `kero_alacritty_new` and must not be used after.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_free(handle: *mut KeroTerminal) {
    if handle.is_null() {
        return;
    }
    let mut terminal = Box::from_raw(handle);
    terminal.frame_handoff.finish();
    let event_loop = terminal.event_loop.take();
    if !terminal.exited {
        let _ = terminal.notifier.0.send(GraphicsMsg::Shutdown);
    }
    drop(terminal);
    if let Some(event_loop) = event_loop {
        let _ = event_loop.join();
    }
}

/// PID of the shell, for Kero's process panel and its teardown signals.
///
/// # Safety
/// `handle` must be a live handle from `kero_alacritty_new`.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_child_pid(handle: *mut KeroTerminal) -> i32 {
    if handle.is_null() {
        return 0;
    }
    (*handle).child_pid
}

/// PID of the foreground process group on the PTY — the running job rather
/// than the shell that launched it. Falls back to the shell's own PID.
///
/// # Safety
/// `handle` must be a live handle from `kero_alacritty_new`.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_foreground_pid(handle: *mut KeroTerminal) -> i32 {
    if handle.is_null() {
        return 0;
    }
    let terminal = &*handle;
    let pgid = libc_tcgetpgrp(terminal.master_fd);
    if pgid > 0 {
        pgid
    } else {
        terminal.child_pid
    }
}

extern "C" {
    #[link_name = "tcgetpgrp"]
    fn libc_tcgetpgrp(fd: RawFd) -> i32;
}

// MARK: - Input

/// # Safety
/// `handle` must be live and `bytes` valid for `len`.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_write(
    handle: *mut KeroTerminal,
    bytes: *const u8,
    len: usize,
) {
    if handle.is_null() || bytes.is_null() || len == 0 {
        return;
    }
    let terminal = &mut *handle;
    let payload = std::slice::from_raw_parts(bytes, len).to_vec();
    terminal.notifier.notify_user(payload.into());
}

/// Writes focus/mouse protocol input without snapping a viewport the user is
/// reading back to the live prompt.
///
/// # Safety
/// `handle` must be live and `bytes` valid for `len`.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_write_control(
    handle: *mut KeroTerminal,
    bytes: *const u8,
    len: usize,
) {
    if handle.is_null() || bytes.is_null() || len == 0 {
        return;
    }
    let terminal = &mut *handle;
    let payload = std::slice::from_raw_parts(bytes, len).to_vec();
    terminal.notifier.notify(payload);
}

/// Completes a pending OSC 52 clipboard read after Kero's confirmation sheet
/// has resolved it. Denied requests are removed without ever writing clipboard
/// contents to the PTY.
///
/// # Safety
/// `handle` must be live and `bytes` valid for `len` when non-null.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_resolve_clipboard(
    handle: *mut KeroTerminal,
    request_id: u64,
    bytes: *const u8,
    len: usize,
    approved: bool,
) {
    if handle.is_null() {
        return;
    }
    let terminal = &mut *handle;
    let format = {
        let mut shared = terminal.shared.lock();
        let Some(index) = shared
            .pending_clipboard
            .iter()
            .position(|(id, _)| *id == request_id)
        else {
            return;
        };
        shared
            .pending_clipboard
            .remove(index)
            .map(|(_, format)| format)
    };
    let Some(format) = format else { return };
    if !approved {
        return;
    }
    let text = if bytes.is_null() || len == 0 {
        ""
    } else {
        std::str::from_utf8(std::slice::from_raw_parts(bytes, len)).unwrap_or("")
    };
    terminal.notifier.notify(format(text).into_bytes());
}

/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_resize(
    handle: *mut KeroTerminal,
    columns: u16,
    rows: u16,
    cell_width: u16,
    cell_height: u16,
) {
    if handle.is_null() {
        return;
    }
    let terminal = &mut *handle;
    let window_size = WindowSize {
        num_lines: rows.max(1),
        num_cols: columns.max(1),
        cell_width: cell_width.max(1),
        cell_height: cell_height.max(1),
    };
    let size = TermSize {
        columns: columns.max(1) as usize,
        screen_lines: rows.max(1) as usize,
    };
    // Keep the terminal lock through the pre-invalidation and barrier enqueue.
    // A queued Find step can finish against the old geometry before this
    // resize, or it will see the cleared state and the barrier after the
    // mutation; it cannot reuse old points between the mutation and enqueue.
    let mut term = terminal.term.lock();
    let preinvalidated_generation = terminal.find_state.lock().invalidate();
    term.resize(size);
    terminal.shared.lock().window_size = window_size;
    *terminal.kitty_graphics_size.lock() = KittyGraphicsSize {
        columns: columns.max(1) as usize,
        rows: rows.max(1) as usize,
        cell_width: f32::from(cell_width.max(1)),
        cell_height: f32::from(cell_height.max(1)),
    };
    if let Some(generation) = preinvalidated_generation {
        terminal.notifier.invalidate_find_generation(generation);
    }
    terminal.notifier.on_resize(window_size);
}

/// Scrolls by `delta` lines, positive toward older output.
///
/// Host scroll intent should ride `kero_alacritty_begin_frame`'s
/// `pending_scroll` instead: this acquires the term lock per call, which at
/// trackpad-event rate contends with the PTY parse thread. It stays for
/// callers that scroll outside the render loop.
///
/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_scroll(handle: *mut KeroTerminal, delta: i32) {
    if handle.is_null() {
        return;
    }
    (*handle).term.lock().scroll_display(Scroll::Delta(delta));
}

/// # Safety
/// `handle` must be live and `theme` valid for the call.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_set_theme(
    handle: *mut KeroTerminal,
    theme: *const KeroTheme,
) {
    if handle.is_null() || theme.is_null() {
        return;
    }
    let theme = *theme;
    let terminal = &mut *handle;
    terminal.theme = theme;
    // Packed rows carry resolved colors; a new palette makes them stale even
    // though no line moved.
    terminal.snapshot_cache.generation = terminal.snapshot_cache.generation.wrapping_add(1);
    terminal.snapshot_cache.rows.clear();
    // ColorRequest on the PTY thread still reads Shared.
    terminal.shared.lock().theme = theme;
}

/// Updates the default cursor used when the terminal application has not
/// explicitly selected its own DECSCUSR style.
///
/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_set_cursor_style(
    handle: *mut KeroTerminal,
    shape: u8,
    blinking: bool,
) {
    if handle.is_null() {
        return;
    }
    let terminal = &mut *handle;
    terminal.term_config.default_cursor_style = configured_cursor_style(shape, blinking);
    let term_config = terminal.term_config.clone();
    terminal.term.lock().set_options(term_config);
}

// MARK: - Selection

/// Starts a selection at a viewport cell. `kind` is 0 simple, 1 semantic
/// (word), 2 line — matching single, double, and triple click.
/// Returns false when the terminal is busy.
///
/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_selection_start(
    handle: *mut KeroTerminal,
    line: i32,
    column: usize,
    kind: u32,
    right_half: bool,
) -> bool {
    if handle.is_null() {
        return false;
    }
    let terminal = &mut *handle;
    let Some(mut term) = try_ui_lock(&terminal.term) else {
        return false;
    };
    let offset = term.grid().display_offset();
    let point = Point::new(Line(line - offset as i32), Column(column));
    let side = if right_half { Side::Right } else { Side::Left };
    let selection_type = match kind {
        1 => SelectionType::Semantic,
        2 => SelectionType::Lines,
        _ => SelectionType::Simple,
    };
    term.selection = Some(Selection::new(selection_type, point, side));
    true
}

/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_selection_update(
    handle: *mut KeroTerminal,
    line: i32,
    column: usize,
    right_half: bool,
) -> bool {
    if handle.is_null() {
        return false;
    }
    let terminal = &mut *handle;
    let Some(mut term) = try_ui_lock(&terminal.term) else {
        return false;
    };
    let offset = term.grid().display_offset();
    let point = Point::new(Line(line - offset as i32), Column(column));
    let side = if right_half { Side::Right } else { Side::Left };
    if let Some(selection) = term.selection.as_mut() {
        selection.update(point, side);
    }
    true
}

/// Selects every row, scrollback included. Returns false when the terminal is
/// busy; the UI caller should retry.
///
/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_select_all(handle: *mut KeroTerminal) -> bool {
    if handle.is_null() {
        return false;
    }
    let terminal = &mut *handle;
    let Some(mut term) = try_ui_lock(&terminal.term) else {
        return false;
    };
    let start = Point::new(term.topmost_line(), Column(0));
    let end = Point::new(term.bottommost_line(), term.last_column());
    let mut selection = Selection::new(SelectionType::Simple, start, Side::Left);
    selection.update(end, Side::Right);
    term.selection = Some(selection);
    true
}

/// Drops the current selection, if any. Returns whether a selection was present.
/// Returns false when the terminal is busy.
///
/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_clear_selection(handle: *mut KeroTerminal) -> bool {
    if handle.is_null() {
        return false;
    }
    let Some(mut term) = try_ui_lock(&(*handle).term) else {
        return false;
    };
    let had = term.selection.is_some();
    term.selection = None;
    had
}

/// Queues selection clearing on the PTY worker without waiting for the
/// terminal lock. The worker keeps the viewport where it is and wakes the
/// host only when a selection was present.
///
/// # Safety
/// `handle` must be live, or null.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_clear_selection_async(handle: *mut KeroTerminal) {
    if handle.is_null() {
        return;
    }
    (*handle).notifier.clear_selection_async();
}

/// Reports whether the current selection query acquired the terminal lock.
///
/// # Safety
/// `handle` must be live, or null.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_selection_state(handle: *mut KeroTerminal) -> u32 {
    if handle.is_null() {
        return KERO_SELECTION_BUSY;
    }
    let Some(term) = try_ui_lock(&(*handle).term) else {
        return KERO_SELECTION_BUSY;
    };
    if term.selection.is_some() {
        KERO_SELECTION_PRESENT
    } else {
        KERO_SELECTION_EMPTY
    }
}

/// Whether anything is selected. Returns false when the terminal is busy.
///
/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_has_selection(handle: *mut KeroTerminal) -> bool {
    if handle.is_null() {
        return false;
    }
    let Some(term) = try_ui_lock(&(*handle).term) else {
        return false;
    };
    term.selection.is_some()
}

/// Copies the selection into `buffer`, returning the byte length written, or
/// the length required when `buffer` is null or `capacity` is too small.
/// Returns zero when the terminal is busy.
///
/// # Safety
/// `handle` must be live and `buffer` valid for `capacity` bytes.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_selection_text(
    handle: *mut KeroTerminal,
    buffer: *mut u8,
    capacity: usize,
) -> usize {
    if handle.is_null() {
        return 0;
    }
    let text = {
        let Some(term) = try_ui_lock(&(*handle).term) else {
            return 0;
        };
        term.selection_to_string().unwrap_or_default()
    };
    let bytes = text.as_bytes();
    if buffer.is_null() || capacity < bytes.len() {
        return bytes.len();
    }
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), buffer, bytes.len());
    bytes.len()
}

// MARK: - Find

/// Counts every match of `needle` in the screen and scrollback, and selects
/// the one nearest the viewport.
///
/// The needle is matched literally: Kero's find bar is a plain text field, so
/// regex metacharacters in it are escaped rather than interpreted.
///
/// # Safety
/// `handle` must be live and `needle` a valid C string.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_find(
    handle: *mut KeroTerminal,
    needle: *const c_char,
) -> usize {
    if handle.is_null() {
        return 0;
    }
    let terminal = &mut *handle;
    let needle = cstr(needle).unwrap_or_default();
    let mut term = terminal.term.lock();
    let mut find_state = terminal.find_state.lock();
    apply_find_message(
        &mut term,
        &mut find_state,
        FindMessage::Begin {
            generation: 0,
            needle,
        },
    )
    .total
}

/// Selects and reveals the next or previous match, returning its zero-based
/// index, or -1 when there are none.
///
/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_find_step(
    handle: *mut KeroTerminal,
    forward: bool,
) -> isize {
    if handle.is_null() {
        return -1;
    }
    let terminal = &mut *handle;
    let mut term = terminal.term.lock();
    let mut find_state = terminal.find_state.lock();
    apply_find_message(
        &mut term,
        &mut find_state,
        FindMessage::Step {
            generation: 0,
            forward,
        },
    )
    .selected
}

/// Clears the find and its selection.
///
/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_find_end(handle: *mut KeroTerminal) {
    if handle.is_null() {
        return;
    }
    let terminal = &mut *handle;
    let mut term = terminal.term.lock();
    let mut find_state = terminal.find_state.lock();
    let _ = apply_find_message(
        &mut term,
        &mut find_state,
        FindMessage::End { generation: 0 },
    );
}

/// Queues a find begin on the PTY worker. The call does not inspect the
/// terminal or scan its scrollback.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_find_begin_async(
    handle: *mut KeroTerminal,
    needle: *const c_char,
    generation: u64,
) -> bool {
    if handle.is_null() || generation == 0 {
        return false;
    }
    let Some(needle) = cstr(needle) else {
        return false;
    };
    (*handle).notifier.find_begin(generation, needle)
}

/// Queues a find navigation step on the PTY worker without taking the
/// terminal lock on the caller's thread.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_find_step_async(
    handle: *mut KeroTerminal,
    forward: bool,
    generation: u64,
) -> bool {
    if handle.is_null() || generation == 0 {
        return false;
    }
    (*handle).notifier.find_step(generation, forward)
}

/// Queues find cleanup on the PTY worker. FIFO ordering keeps it after any
/// already queued begin or step message for the same handle.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_find_end_async(
    handle: *mut KeroTerminal,
    generation: u64,
) -> bool {
    if handle.is_null() || generation == 0 {
        return false;
    }
    (*handle).notifier.find_end(generation)
}

/// Reads the newest worker result without waiting for the terminal lock.
/// `out` remains unchanged while no result is available.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_find_poll(
    handle: *mut KeroTerminal,
    out: *mut KeroFindResult,
) -> bool {
    if handle.is_null() || out.is_null() {
        return false;
    }
    let Some(result) = (*handle).find_results.read() else {
        return false;
    };
    *out = KeroFindResult {
        generation: result.generation,
        kind: result.kind,
        total: result.total,
        selected: result.selected,
    };
    true
}

/// Escapes a literal needle for the regex engine, so a search for `a.b` does
/// not also match `axb`.
fn regex_escape(needle: &str) -> String {
    let mut escaped = String::with_capacity(needle.len() * 2);
    for character in needle.chars() {
        if "\\.+*?()|[]{}^$".contains(character) {
            escaped.push('\\');
        }
        escaped.push(character);
    }
    escaped
}

// MARK: - Screen contents

#[derive(Clone, Debug, PartialEq, Eq)]
struct VtStyle {
    foreground: u32,
    background: u32,
    flags: u16,
    hyperlink: Option<String>,
}

fn style_for(cell: &Cell, colors: &Colors, theme: &KeroTheme) -> VtStyle {
    let mut flags = 0;
    for (source, target) in [
        (Flags::BOLD, KERO_CELL_BOLD),
        (Flags::ITALIC, KERO_CELL_ITALIC),
        (Flags::STRIKEOUT, KERO_CELL_STRIKEOUT),
        (Flags::DIM, KERO_CELL_DIM),
        (Flags::HIDDEN, KERO_CELL_HIDDEN),
        (Flags::INVERSE, KERO_CELL_INVERSE),
    ] {
        if cell.flags.contains(source) {
            flags |= target;
        }
    }
    if cell.flags.intersects(Flags::ALL_UNDERLINES) {
        flags |= KERO_CELL_UNDERLINE;
    }
    VtStyle {
        foreground: resolve(cell.fg, colors, theme),
        background: resolve(cell.bg, colors, theme),
        flags,
        hyperlink: cell.hyperlink().map(|link| link.uri().to_owned()),
    }
}

fn push_sgr(output: &mut Vec<u8>, style: &VtStyle) {
    let foreground = unpack(style.foreground);
    let background = unpack(style.background);
    let mut codes = vec![
        "0".to_owned(),
        format!("38;2;{};{};{}", foreground.r, foreground.g, foreground.b),
        format!("48;2;{};{};{}", background.r, background.g, background.b),
    ];
    for (flag, code) in [
        (KERO_CELL_BOLD, "1"),
        (KERO_CELL_DIM, "2"),
        (KERO_CELL_ITALIC, "3"),
        (KERO_CELL_UNDERLINE, "4"),
        (KERO_CELL_INVERSE, "7"),
        (KERO_CELL_HIDDEN, "8"),
        (KERO_CELL_STRIKEOUT, "9"),
    ] {
        if style.flags & flag != 0 {
            codes.push(code.to_owned());
        }
    }
    output.extend_from_slice(b"\x1b[");
    output.extend_from_slice(codes.join(";").as_bytes());
    output.push(b'm');
}

fn push_hyperlink(output: &mut Vec<u8>, uri: Option<&str>) {
    output.extend_from_slice(b"\x1b]8;;");
    if let Some(uri) = uri {
        output.extend_from_slice(uri.as_bytes());
    }
    output.extend_from_slice(b"\x1b\\");
}

fn cell_has_visible_content(cell: &Cell) -> bool {
    cell.c != ' '
        || cell.zerowidth().is_some_and(|marks| !marks.is_empty())
        || cell.fg != Color::Named(NamedColor::Foreground)
        || cell.bg != Color::Named(NamedColor::Background)
        || cell.flags.intersects(
            Flags::BOLD
                | Flags::ITALIC
                | Flags::ALL_UNDERLINES
                | Flags::STRIKEOUT
                | Flags::DIM
                | Flags::HIDDEN
                | Flags::INVERSE,
        )
        || cell.hyperlink().is_some()
}

/// Serializes screen contents with enough VT state to replay their appearance
/// into either backend. Soft-wrapped rows stay joined so the new terminal can
/// reflow them at its current width.
fn serialize_vt<T: EventListener>(
    term: &Term<T>,
    theme: &KeroTheme,
    scrollback_only: bool,
) -> Vec<u8> {
    let first_line = term.topmost_line();
    let last_line = if scrollback_only {
        Line(-1)
    } else {
        term.bottommost_line()
    };
    if last_line < first_line {
        return Vec::new();
    }

    let colors = term.colors();
    let columns = term.columns();
    let mut output = Vec::new();
    let mut active_style: Option<VtStyle> = None;
    let mut active_link: Option<String> = None;

    for line in (first_line.0..=last_line.0).map(Line::from) {
        let row = &term.grid()[line];
        let wrapped = row[Column(columns - 1)].flags.contains(Flags::WRAPLINE);
        let length = if wrapped {
            columns
        } else {
            row[..]
                .iter()
                .rposition(cell_has_visible_content)
                .map_or(0, |column| column + 1)
        };

        for column in 0..length {
            let cell = &row[Column(column)];
            if cell
                .flags
                .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
            {
                continue;
            }

            let style = style_for(cell, colors, theme);
            if active_style.as_ref() != Some(&style) {
                if active_link.as_deref() != style.hyperlink.as_deref() {
                    if active_link.is_some() {
                        push_hyperlink(&mut output, None);
                    }
                    if let Some(uri) = style.hyperlink.as_deref() {
                        push_hyperlink(&mut output, Some(uri));
                    }
                    active_link = style.hyperlink.clone();
                }
                push_sgr(&mut output, &style);
                active_style = Some(style);
            }

            let mut encoded = [0; 4];
            output.extend_from_slice(cell.c.encode_utf8(&mut encoded).as_bytes());
            for mark in cell.zerowidth().into_iter().flatten() {
                output.extend_from_slice(mark.encode_utf8(&mut encoded).as_bytes());
            }
        }

        if !wrapped {
            if active_link.take().is_some() {
                push_hyperlink(&mut output, None);
            }
            if active_style.take().is_some() {
                output.extend_from_slice(b"\x1b[0m");
            }
            output.extend_from_slice(b"\r\n");
        }
    }
    if active_link.is_some() {
        push_hyperlink(&mut output, None);
    }
    if active_style.is_some() {
        output.extend_from_slice(b"\x1b[0m");
    }
    output
}

/// Writes the whole buffer — scrollback and screen — as a styled VT stream
/// into `buffer`, using the same length protocol as selection text. This backs
/// Kero's history capture and its tab-switcher previews.
///
/// # Safety
/// `handle` must be live and `buffer` valid for `capacity` bytes.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_buffer_text(
    handle: *mut KeroTerminal,
    scrollback_only: bool,
    buffer: *mut u8,
    capacity: usize,
) -> usize {
    if handle.is_null() {
        return 0;
    }
    let terminal = &mut *handle;
    let theme = terminal.shared.lock().theme;
    let term = terminal.term.lock();
    let bytes = serialize_vt(&term, &theme, scrollback_only);
    if buffer.is_null() || capacity < bytes.len() {
        return bytes.len();
    }
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), buffer, bytes.len());
    bytes.len()
}

/// Apply the same URL delimiter heuristics as Alacritty's hint system.
fn post_process_url_match<T: EventListener>(term: &Term<T>, regex_match: &Match) -> Option<Match> {
    let mut iter = term.grid().iter_from(*regex_match.start());
    let mut c = iter.cell().c;

    // A URL inside prose commonly ends immediately before an unmatched
    // closing bracket, while balanced brackets can legitimately be in a URL.
    let end = *regex_match.end();
    let mut open_parens = 0;
    let mut open_brackets = 0;
    loop {
        match c {
            '(' => open_parens += 1,
            '[' => open_brackets += 1,
            ')' if open_parens == 0 => {
                iter.prev();
                break;
            }
            ')' => open_parens -= 1,
            ']' if open_brackets == 0 => {
                iter.prev();
                break;
            }
            ']' => open_brackets -= 1,
            _ => {}
        }

        if iter.point() == end {
            break;
        }

        let Some(indexed) = iter.next() else {
            break;
        };
        c = indexed.cell.c;
    }

    let start = *regex_match.start();
    while iter.point() != start {
        if !matches!(c, '.' | ',' | ':' | ';' | '?' | '!' | '(' | '[' | '\'') {
            break;
        }

        let Some(indexed) = iter.prev() else {
            break;
        };
        c = indexed.cell.c;
    }

    (start <= iter.point()).then(|| start..=iter.point())
}

/// Finds Alacritty's default plain-text URL hint under a grid point.
fn plain_url_at<T: EventListener>(
    term: &Term<T>,
    regex: &mut RegexSearch,
    point: Point,
) -> Option<(String, Match)> {
    let mut start = term.line_search_left(point);
    let mut end = term.line_search_right(point);
    start.line = start.line.max(point.line - MAX_URL_SEARCH_LINES);
    end.line = end.line.min(point.line + MAX_URL_SEARCH_LINES);

    let raw_match =
        RegexIter::new(start, end, Direction::Right, term, regex).find(|rm| rm.contains(&point))?;
    let raw_end = *raw_match.end();
    let mut next_match = Some(raw_match);

    // Post-processing can split a greedy regex match at an unmatched closing
    // bracket. Keep searching inside the original range so a later URL remains
    // clickable, matching Alacritty's hint behavior.
    while let Some(regex_match) = next_match {
        let processed = post_process_url_match(term, &regex_match);
        if processed.as_ref().is_some_and(|rm| rm.contains(&point)) {
            let bounds = processed.unwrap();
            let url = term.bounds_to_string(*bounds.start(), *bounds.end());
            return Some((url, bounds));
        }

        let next_start = processed
            .as_ref()
            .map_or_else(|| *regex_match.start(), |rm| *rm.end())
            .add(term, Boundary::Grid, 1);
        if next_start > raw_end {
            return None;
        }
        next_match = term.regex_search_right(regex, next_start, raw_end);
    }

    None
}

/// Finds the contiguous OSC 8 hyperlink under a grid point.
fn hyperlink_url_at<T: EventListener>(term: &Term<T>, point: Point) -> Option<(String, Match)> {
    let hyperlink = term.grid()[point].hyperlink()?;
    let grid = term.grid();

    let mut end = point;
    for cell in grid.iter_from(point) {
        if cell.hyperlink().as_ref() == Some(&hyperlink) {
            end = cell.point;
        } else {
            break;
        }
    }

    let mut start = point;
    let mut iter = grid.iter_from(point);
    while let Some(cell) = iter.prev() {
        if cell.hyperlink().as_ref() == Some(&hyperlink) {
            start = cell.point;
        } else {
            break;
        }
    }

    Some((hyperlink.uri().to_owned(), start..=end))
}

/// Returns the OSC 8 hyperlink or plain-text URL under a viewport cell.
///
/// # Safety
/// `handle` must be live; `range` must be null or valid; and `buffer` must be
/// null or valid for `capacity` bytes. Returns zero when the terminal is busy.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_url_at(
    handle: *mut KeroTerminal,
    line: i32,
    column: usize,
    range: *mut KeroURLRange,
    buffer: *mut u8,
    capacity: usize,
) -> usize {
    if handle.is_null() {
        return 0;
    }
    let terminal = &mut *handle;
    let Some(term) = try_ui_lock(&terminal.term) else {
        return 0;
    };
    if line < 0 || line as usize >= term.screen_lines() || column >= term.columns() {
        return 0;
    }
    let offset = term.grid().display_offset();
    let point = Point::new(Line(line - offset as i32), Column(column));
    let Some((url, bounds)) = hyperlink_url_at(&term, point)
        .or_else(|| plain_url_at(&term, &mut terminal.url_regex, point))
    else {
        return 0;
    };
    if !range.is_null() {
        *range = KeroURLRange {
            start_line: bounds.start().line.0 + offset as i32,
            start_column: bounds.start().column.0,
            end_line: bounds.end().line.0 + offset as i32,
            end_column: bounds.end().column.0,
        };
    }
    let bytes = url.as_bytes();
    if buffer.is_null() || capacity < bytes.len() {
        return bytes.len();
    }
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), buffer, bytes.len());
    bytes.len()
}

/// Clears the screen and the scrollback.
///
/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_clear(handle: *mut KeroTerminal) {
    if handle.is_null() {
        return;
    }
    let mut term = (*handle).term.lock();
    let preinvalidated_generation = (*handle).find_state.lock().invalidate();
    term.grid_mut().clear_viewport();
    term.grid_mut().clear_history();
    {
        let mut graphics = (*handle).kitty_graphics.lock();
        let primary = graphics.state.clear_screen(KittyGraphicsScreen::Primary);
        let alternate = graphics.state.clear_screen(KittyGraphicsScreen::Alternate);
        if primary || alternate {
            graphics.mark_changed();
        }
    }
    // Queue the invalidation while the terminal lock is still held. This
    // makes the reset visible to the worker before it can start another Find
    // chunk, while preserving FIFO order for the next user-input message.
    if let Some(generation) = preinvalidated_generation {
        (*handle).notifier.invalidate_find_generation(generation);
    } else {
        (*handle).notifier.invalidate_find();
    }
}

/// Whether Alacritty is buffering a DEC synchronized update.
///
/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_synchronized_update(handle: *mut KeroTerminal) -> bool {
    if handle.is_null() {
        return false;
    }
    (*handle).shared.lock().synchronized_update
}

#[cfg(test)]
mod tests {
    use super::*;
    use alacritty_terminal::event::VoidListener;
    use alacritty_terminal::vte::ansi::Processor;
    use kitty_graphics::{KittyGraphicsInterceptor, KittyGraphicsItem};

    fn intercept(interceptor: &mut OscInterceptor, input: &[u8]) -> (Vec<u8>, Vec<OscEvent>) {
        let (output, events) = interceptor.process(input);
        (output.into_owned(), events)
    }

    #[test]
    fn configured_cursor_style_maps_shape_and_blinking() {
        let block = configured_cursor_style(0, true);
        assert_eq!(block.shape, CursorShape::Block);
        assert!(block.blinking);

        let underline = configured_cursor_style(1, false);
        assert_eq!(underline.shape, CursorShape::Underline);
        assert!(!underline.blinking);

        let beam = configured_cursor_style(2, true);
        assert_eq!(beam.shape, CursorShape::Beam);
        assert!(beam.blinking);
    }

    #[test]
    fn terminal_options_update_the_default_cursor_live() {
        let size = TermSize {
            columns: 40,
            screen_lines: 3,
        };
        let mut config = Config::default();
        let mut term = Term::new(config.clone(), &size, VoidListener);

        config.default_cursor_style = configured_cursor_style(1, false);
        term.set_options(config);

        let cursor = term.cursor_style();
        assert_eq!(cursor.shape, CursorShape::Underline);
        assert!(!cursor.blinking);
    }

    #[test]
    fn stream_scanner_handles_every_chunk_boundary() {
        let input = b"\x1b[?2026hframe\x1b[?2026l\x1bc";
        let expected = vec![
            ScanEvent::SyncUpdate(SyncUpdateEvent::Start),
            ScanEvent::SyncUpdate(SyncUpdateEvent::End),
            ScanEvent::MouseShape("text"),
        ];

        for split in 0..=input.len() {
            let mut scanner = StreamScanner::default();
            let mut events = scanner.process(&input[..split]);
            events.extend(scanner.process(&input[split..]));
            assert_eq!(events, expected, "split at {split}");
        }
    }

    #[test]
    fn stream_scanner_ignores_sequences_inside_control_strings() {
        let mut scanner = StreamScanner::default();
        let events = scanner.process(b"\x1b]0;\x1b[?2026h\x07\x1bPpayload\x1b[?2026l\x1b\\");

        assert!(events.is_empty());
    }

    #[test]
    fn stream_scanner_accepts_c1_csi() {
        let mut scanner = StreamScanner::default();
        assert_eq!(
            scanner.process(b"\x9b?2026h\x9b?2026l"),
            vec![
                ScanEvent::SyncUpdate(SyncUpdateEvent::Start),
                ScanEvent::SyncUpdate(SyncUpdateEvent::End),
            ]
        );
    }

    #[test]
    fn stream_scanner_couples_mouse_reporting_to_pointer_shape() {
        let mut scanner = StreamScanner::default();
        assert_eq!(
            scanner.process(b"\x1b[?1002;1006h\x1b[?1000l"),
            vec![
                ScanEvent::MouseShape("default"),
                ScanEvent::MouseShape("text"),
            ]
        );
        // Non-private modes and unrelated DEC modes stay silent.
        assert!(scanner.process(b"\x1b[9h\x1b[?25l").is_empty());
    }

    #[test]
    fn mode_snapshot_maps_the_terminal_owner_bits() {
        let snapshot = ModeSnapshot::new();
        snapshot.store_term_mode(
            TermMode::APP_CURSOR
                | TermMode::APP_KEYPAD
                | TermMode::ALT_SCREEN
                | TermMode::BRACKETED_PASTE
                | TermMode::MOUSE_DRAG
                | TermMode::FOCUS_IN_OUT
                | TermMode::SGR_MOUSE
                | TermMode::ALTERNATE_SCROLL,
        );
        assert_eq!(
            snapshot.load(),
            MODE_APP_CURSOR
                | MODE_APP_KEYPAD
                | MODE_ALT_SCREEN
                | MODE_BRACKETED_PASTE
                | MODE_MOUSE
                | MODE_MOUSE_DRAG
                | MODE_FOCUS_IN_OUT
                | MODE_SGR_MOUSE
                | MODE_ALTERNATE_SCROLL
        );
    }

    #[test]
    fn stream_scanner_restores_text_shape_on_full_reset() {
        let mut scanner = StreamScanner::default();
        assert_eq!(
            scanner.process(b"\x1bc"),
            vec![ScanEvent::MouseShape("text")]
        );
        // A charset designation's final byte and a `c` inside a control
        // string must not read as RIS.
        assert!(scanner.process(b"\x1b(c").is_empty());
        assert!(scanner.process(b"\x1b]0;\x1bc\x07").is_empty());
    }

    fn theme() -> KeroTheme {
        let mut palette = [0; 256];
        for (index, color) in palette.iter_mut().enumerate() {
            *color = index as u32 * 0x010101;
        }
        KeroTheme {
            palette,
            foreground: 0xeeeeee,
            background: 0x111111,
            cursor: 0xffffff,
        }
    }

    fn parse(input: &[u8]) -> Term<VoidListener> {
        let size = TermSize {
            columns: 40,
            screen_lines: 3,
        };
        let mut term = Term::new(Config::default(), &size, VoidListener);
        let mut processor: Processor = Processor::new();
        processor.advance(&mut term, input);
        term
    }

    #[test]
    fn snapshot_cache_reuses_rows_across_scroll() {
        // Five lines in a three-line screen: two lines of history above the
        // viewport "three four five".
        let mut term = parse(b"one\r\ntwo\r\nthree\r\nfour\r\nfive");
        let mut snap = SnapshotState::new();
        snap.fill(&term, None);
        let generation = snap.out.row_generation;
        assert_eq!(snap.cache.rows.len(), 3);
        let ids: Vec<u64> = (0..snap.out.rows)
            .map(|row| unsafe { *snap.out.row_ids.add(row) })
            .collect();
        assert_eq!(ids, vec![2, 3, 4]);

        // A pure host scroll moves the window without touching any line: the
        // two newly revealed rows are packed, the three old rows are reused,
        // and the generation survives.
        term.scroll_display(Scroll::Delta(2));
        term.reset_damage();
        snap.fill(&term, None);
        assert_eq!(snap.out.row_generation, generation);
        assert_eq!(snap.cache.rows.len(), 5);
        let ids: Vec<u64> = (0..snap.out.rows)
            .map(|row| unsafe { *snap.out.row_ids.add(row) })
            .collect();
        assert_eq!(ids, vec![0, 1, 2]);
        assert_eq!(snap.ch(0, 1), 'n'); // "one"
        assert_eq!(snap.ch(1, 1), 'w'); // "two"
        assert_eq!(snap.ch(2, 1), 'h'); // "three"

        // Growth at the bottom keeps every existing id: the viewport slides,
        // nothing is invalidated.
        write_vt(&mut term, b"\r\nsix");
        term.reset_damage();
        snap.fill(&term, None);
        assert_eq!(snap.out.row_generation, generation);
        assert_eq!(snap.out.total_lines, 6);

        // A parser full-damage report forces a complete repack even when the
        // retained line count does not change.
        write_vt(&mut term, b"\rSEVEN");
        term.reset_damage();
        snap.fill_repack(&term);
        assert_ne!(snap.out.row_generation, generation);
    }

    #[test]
    fn frame_verdict_prefers_host_and_full_over_cursor() {
        assert_eq!(
            frame_verdict(false, false, KERO_DAMAGE_NONE),
            KERO_FRAME_SKIP
        );
        assert_eq!(
            frame_verdict(false, true, KERO_DAMAGE_NONE),
            KERO_FRAME_CURSOR
        );
        assert_eq!(
            frame_verdict(false, false, KERO_DAMAGE_PARTIAL),
            KERO_FRAME_DIRTY
        );
        assert_eq!(
            frame_verdict(false, false, KERO_DAMAGE_FULL),
            KERO_FRAME_FULL
        );
        // Host-side changes and full damage outrank everything; a cursor hint
        // loses to real damage because the damaged rows carry the cursor.
        assert_eq!(
            frame_verdict(true, false, KERO_DAMAGE_NONE),
            KERO_FRAME_FULL
        );
        assert_eq!(
            frame_verdict(true, true, KERO_DAMAGE_PARTIAL),
            KERO_FRAME_FULL
        );
        assert_eq!(
            frame_verdict(false, true, KERO_DAMAGE_PARTIAL),
            KERO_FRAME_DIRTY
        );
    }

    #[test]
    fn scroll_display_reports_full_damage_only_when_offset_moves() {
        // Five lines in a three-line screen: two lines of history to scroll
        // into, and the parse damage drained before the assertions.
        let mut term = parse(b"one\r\ntwo\r\nthree\r\nfour\r\nfive");
        term.reset_damage();

        // begin_frame reads parser damage before applying host scrolling. A
        // prior full report must remain visible after that extra read.
        write_vt(&mut term, b"\x1b[4h");
        assert!(matches!(term.damage(), TermDamage::Full));
        write_vt(&mut term, b"\x1b[4l");
        term.reset_damage();

        // A clamped scroll (already at the live bottom, delta toward newer
        // output) moves nothing: damage stays at cursor bookkeeping (old and
        // new cursor rows), which begin_frame refills as a couple of rows
        // rather than a full rebuild.
        term.scroll_display(Scroll::Delta(-5));
        assert!(!matches!(term.damage(), TermDamage::Full));
        term.reset_damage();

        // A pending scroll that moves the offset is what makes a begin_frame
        // with no other changes report FULL.
        term.scroll_display(Scroll::Delta(1));
        let full = match term.damage() {
            TermDamage::Full => true,
            TermDamage::Partial(_) => false,
        };
        assert!(full);
    }

    fn url_in(term: &Term<VoidListener>, point: Point) -> Option<String> {
        let mut regex = RegexSearch::new(LINK_REGEX).unwrap();
        plain_url_at(term, &mut regex, point).map(|(url, _)| url)
    }

    fn url_match_in(term: &Term<VoidListener>, point: Point) -> Option<(String, Match)> {
        let mut regex = RegexSearch::new(LINK_REGEX).unwrap();
        plain_url_at(term, &mut regex, point)
    }

    fn ascii_point(content: &str, needle: &str) -> Point {
        let offset = content.find(needle).unwrap();
        Point::new(Line((offset / 40) as i32), Column(offset % 40))
    }

    #[test]
    fn plain_url_lookup_uses_alacritty_hint_delimiters() {
        let content = "visit (https://example.com/docs). next";
        let term = parse(content.as_bytes());

        assert_eq!(
            url_in(&term, ascii_point(content, "example")),
            Some("https://example.com/docs".to_owned())
        );
        assert_eq!(url_in(&term, ascii_point(content, ").")), None);
    }

    #[test]
    fn plain_url_lookup_follows_soft_wrapped_lines() {
        let content = "prefix https://example.com/a/very/long/path/that/wraps suffix";
        let term = parse(content.as_bytes());

        let (url, bounds) = url_match_in(&term, ascii_point(content, "that")).unwrap();
        assert_eq!(url, "https://example.com/a/very/long/path/that/wraps");
        assert_eq!(*bounds.start(), ascii_point(content, "https"));
        assert_eq!(bounds.end().line, Line(1));
    }

    #[test]
    fn plain_url_lookup_keeps_balanced_parentheses() {
        let content = "https://example.com/a_(balanced)";
        let term = parse(content.as_bytes());

        assert_eq!(
            url_in(&term, ascii_point(content, "balanced")),
            Some(content.to_owned())
        );
    }

    #[test]
    fn plain_url_lookup_matches_local_file_paths() {
        for path in [
            "/tmp/kero/main.swift",
            "~/Developer/kero/main.swift",
            "./Sources/main.swift",
            "../Shared/main.swift",
            "Sources/Kero/main.swift:42:8",
        ] {
            let term = parse(path.as_bytes());
            assert_eq!(
                url_in(&term, ascii_point(path, "main")),
                Some(path.to_owned())
            );
        }
    }

    #[test]
    fn plain_url_lookup_does_not_match_bare_file_names() {
        let path = "main.swift";
        let term = parse(path.as_bytes());

        assert_eq!(url_in(&term, ascii_point(path, "main")), None);
    }

    #[test]
    fn history_export_preserves_style_and_combining_marks() {
        let term = parse(b"\x1b[1;3;38;2;12;34;56mCafe\xcc\x81\x1b[0m");
        let output = serialize_vt(&term, &theme(), false);
        let text = String::from_utf8(output).unwrap();

        assert!(text.contains("\x1b[0;38;2;12;34;56;48;2;17;17;17;1;3m"));
        assert!(text.contains("Cafe\u{301}"));
        assert!(text.contains("\x1b[0m\r\n"));
    }

    #[test]
    fn history_export_preserves_osc8_links() {
        let term = parse(b"\x1b]8;;https://kero.sh\x1b\\Kero\x1b]8;;\x1b\\");
        let output = serialize_vt(&term, &theme(), false);
        let text = String::from_utf8(output).unwrap();

        assert!(text.contains("\x1b]8;;https://kero.sh\x1b\\"));
        assert!(text.contains("Kero"));
        assert!(text.contains("\x1b]8;;\x1b\\"));
    }

    #[test]
    fn osc8_url_lookup_returns_visible_cell_bounds() {
        let term = parse(b"x\x1b]8;;https://kero.sh\x1b\\Kero\x1b]8;;\x1b\\ y");
        let (url, bounds) = hyperlink_url_at(&term, Point::new(Line(0), Column(2))).unwrap();

        assert_eq!(url, "https://kero.sh");
        assert_eq!(
            bounds,
            Point::new(Line(0), Column(1))..=Point::new(Line(0), Column(4))
        );
    }

    #[test]
    fn osc_interceptor_extracts_host_integrations() {
        let mut interceptor = OscInterceptor::default();
        let input = concat!(
            "before",
            "\x1b]7;file://host/Users/egoist/My%20Project\x07",
            "\x1b]9;4;1;150\x1b\\",
            "\x1b]9;Build complete\x07",
            "\x1b]777;notify;Grok;Turn complete\x1b\\",
            "\x1b]133;A\x07",
            "\x1b]133;B\x1b\\",
            "\x1b]133;C\x07",
            "\x1b]133;D;0\x1b\\",
            "after"
        );
        let (output, events) = intercept(&mut interceptor, input.as_bytes());

        assert_eq!(output, b"beforeafter");
        assert_eq!(
            events,
            vec![
                OscEvent::WorkingDirectory("/Users/egoist/My Project".to_owned()),
                OscEvent::Progress {
                    state: 1,
                    percent: Some(100),
                },
                OscEvent::Notification("Build complete".to_owned()),
                OscEvent::Notification("Turn complete".to_owned()),
                OscEvent::ShellPromptStart,
                OscEvent::ShellCommandStart,
                OscEvent::ShellCommandExecuting,
                OscEvent::ShellCommandFinished(Some(0)),
            ]
        );
    }

    #[test]
    fn osc_interceptor_parses_osc777_notification_variants() {
        let mut interceptor = OscInterceptor::default();
        let input = concat!(
            "\x1b]777;notify;Grok;Approval required\x07",
            "\x1b]777;notify;Task complete\x1b\\",
        );
        let (output, events) = intercept(&mut interceptor, input.as_bytes());

        assert!(output.is_empty());
        assert_eq!(
            events,
            vec![
                OscEvent::Notification("Approval required".to_owned()),
                OscEvent::Notification("Task complete".to_owned()),
            ]
        );
    }

    #[test]
    fn osc_interceptor_parses_shell_completion_variants() {
        let mut interceptor = OscInterceptor::default();
        let input = concat!(
            "\x1b]133;D\x07",
            "\x1b]133;D;\x07",
            "\x1b]133;D;17;aid=build\x07",
        );
        let (output, events) = intercept(&mut interceptor, input.as_bytes());

        assert!(output.is_empty());
        assert_eq!(
            events,
            vec![
                OscEvent::ShellCommandFinished(None),
                OscEvent::ShellCommandFinished(None),
                OscEvent::ShellCommandFinished(Some(17)),
            ]
        );
    }

    #[test]
    fn osc_interceptor_parses_mouse_shape_variants() {
        let mut interceptor = OscInterceptor::default();
        let input = concat!(
            "\x1b]22;pointer\x07",
            "\x1b]22;ns-resize\x1b\\",
            // Empty and control-laden names are dropped, but still consumed so
            // Alacritty never sees a sequence it cannot use.
            "\x1b]22;\x07",
            "\x1b]22;bad\nshape\x07",
        );
        let (output, events) = intercept(&mut interceptor, input.as_bytes());

        assert!(output.is_empty());
        assert_eq!(
            events,
            vec![
                OscEvent::MouseShape("pointer".to_owned()),
                OscEvent::MouseShape("ns-resize".to_owned()),
            ]
        );
    }

    #[test]
    fn osc_interceptor_preserves_sequences_owned_by_alacritty() {
        let mut interceptor = OscInterceptor::default();
        let input = b"\x1b]8;;https://kero.sh\x1b\\Kero\x1b]8;;\x1b\\";
        let (output, events) = intercept(&mut interceptor, input);

        assert_eq!(output, b"\x1b]8;;https://kero.sh\x07Kero\x1b]8;;\x07");
        assert!(events.is_empty());
    }

    #[test]
    fn osc_interceptor_handles_every_chunk_boundary() {
        let input = b"left\x1b]133;D;17\x1b\\right";
        let expected = (
            b"leftright".to_vec(),
            vec![OscEvent::ShellCommandFinished(Some(17))],
        );

        for split in 0..=input.len() {
            let mut interceptor = OscInterceptor::default();
            let (first_output, mut events) = intercept(&mut interceptor, &input[..split]);
            let (second_output, second_events) = intercept(&mut interceptor, &input[split..]);
            let mut output = first_output;
            output.extend(second_output);
            events.extend(second_events);
            assert_eq!((output, events), expected, "split at {split}");
        }
    }

    #[test]
    fn osc_interceptor_rejects_control_characters_in_host_events() {
        let mut interceptor = OscInterceptor::default();
        let (output, events) = intercept(
            &mut interceptor,
            b"\x1b]7;file://host/tmp/project\nspoof\x07\x1b]9;bad\nmessage\x07",
        );

        assert!(output.is_empty());
        assert!(events.is_empty());
    }

    fn write_vt(term: &mut Term<VoidListener>, input: &[u8]) {
        let mut processor: Processor = Processor::new();
        processor.advance(term, input);
    }

    fn empty_snapshot() -> KeroSnapshot {
        KeroSnapshot {
            cells: std::ptr::null(),
            columns: 0,
            rows: 0,
            cursor_line: 0,
            cursor_column: 0,
            cursor_shape: 0,
            cursor_color: 0,
            background: 0,
            cursor_blinking: false,
            text: std::ptr::null(),
            text_len: 0,
            display_offset: 0,
            total_lines: 0,
            screen_lines: 0,
            row_ids: std::ptr::null(),
            row_generation: 0,
            ime_cursor_line: -1,
            ime_cursor_column: -1,
        }
    }

    fn empty_kitty_snapshot() -> KeroKittySnapshot {
        KeroKittySnapshot {
            revision: 0,
            placements: std::ptr::null(),
            placements_len: 0,
        }
    }

    fn empty_frame() -> KeroFrame {
        KeroFrame {
            kind: KERO_FRAME_SKIP,
            dirty_rows: std::ptr::null(),
            dirty_rows_len: 0,
            busy_count: 0,
            lock_wait_ns: 0,
            snapshot_ns: 0,
            build_ns: 0,
            packed_rows: 0,
            snapshot: empty_snapshot(),
            kitty: empty_kitty_snapshot(),
        }
    }

    #[derive(Debug, PartialEq, Eq)]
    struct SnapshotFields {
        cells: usize,
        columns: usize,
        rows: usize,
        cursor_line: isize,
        cursor_column: isize,
        cursor_shape: u32,
        cursor_color: u32,
        background: u32,
        cursor_blinking: bool,
        text: usize,
        text_len: usize,
        display_offset: usize,
        total_lines: usize,
        screen_lines: usize,
        row_ids: usize,
        row_generation: u64,
        ime_cursor_line: isize,
        ime_cursor_column: isize,
    }

    fn snapshot_fields(snapshot: &KeroSnapshot) -> SnapshotFields {
        SnapshotFields {
            cells: snapshot.cells as usize,
            columns: snapshot.columns,
            rows: snapshot.rows,
            cursor_line: snapshot.cursor_line,
            cursor_column: snapshot.cursor_column,
            cursor_shape: snapshot.cursor_shape,
            cursor_color: snapshot.cursor_color,
            background: snapshot.background,
            cursor_blinking: snapshot.cursor_blinking,
            text: snapshot.text as usize,
            text_len: snapshot.text_len,
            display_offset: snapshot.display_offset,
            total_lines: snapshot.total_lines,
            screen_lines: snapshot.screen_lines,
            row_ids: snapshot.row_ids as usize,
            row_generation: snapshot.row_generation,
            ime_cursor_line: snapshot.ime_cursor_line,
            ime_cursor_column: snapshot.ime_cursor_column,
        }
    }

    fn kitty_fields(snapshot: &KeroKittySnapshot) -> (u64, usize, usize) {
        (
            snapshot.revision,
            snapshot.placements as usize,
            snapshot.placements_len,
        )
    }

    fn add_test_kitty_placement(terminal: &KeroTerminal) {
        let mut interceptor = KittyGraphicsInterceptor::default();
        let items = interceptor.process(b"\x1b_Ga=T,f=32,s=1,v=1,i=7,c=1,r=1;AQID/w==\x1b\\");
        let command = items
            .into_iter()
            .find_map(|item| match item {
                KittyGraphicsItem::Command(command) => Some(command),
                KittyGraphicsItem::Text(_) => None,
            })
            .expect("test Kitty command");
        let size = *terminal.kitty_graphics_size.lock_unfair();
        let term_mutex = Arc::clone(&terminal.term);
        let term = term_mutex.lock_unfair();
        let cursor = term.grid().cursor.point;
        let history_size = term.grid().history_size();
        drop(term);
        let graphics_mutex = Arc::clone(&terminal.kitty_graphics);
        let mut graphics = graphics_mutex.lock_unfair();
        let result = graphics.state.apply(
            command,
            cursor.column.0,
            cursor.line.0.max(0) as usize,
            history_size,
            size,
            KittyGraphicsScreen::Primary,
        );
        assert!(result.changed);
        graphics.mark_changed();
    }

    extern "C" fn test_callback(_context: *mut c_void, _kind: u32, _data: *const u8, _len: usize) {}

    fn test_terminal_with_damage() -> KeroTerminal {
        let theme = theme();
        let window_size = WindowSize {
            num_lines: 3,
            num_cols: 40,
            cell_width: 1,
            cell_height: 1,
        };
        let shared = Arc::new(FairMutex::new(Shared {
            theme,
            window_size,
            synchronized_update: false,
            synchronized_update_ending: false,
            synchronized_update_deadline: None,
            pending_clipboard: VecDeque::new(),
            next_clipboard_id: 1,
        }));
        let proxy = Proxy {
            callback: test_callback,
            context: SwiftContext(std::ptr::null_mut()),
            sender: Arc::new(OnceLock::new()),
            shared: shared.clone(),
        };
        let term_config = Config::default();
        let size = TermSize {
            columns: 40,
            screen_lines: 3,
        };
        let term = Arc::new(FairMutex::new(Term::new(term_config.clone(), &size, proxy)));
        let kitty_graphics = Arc::new(FairMutex::new(KittyGraphicsStore::default()));
        let kitty_graphics_size = Arc::new(FairMutex::new(KittyGraphicsSize {
            columns: 40,
            rows: 3,
            cell_width: 1.0,
            cell_height: 1.0,
        }));
        let terminal = KeroTerminal {
            event_loop: None,
            term,
            mode_snapshot: ModeSnapshot::new(),
            term_config,
            notifier: GraphicsNotifier::for_test(),
            shared,
            kitty_graphics,
            kitty_graphics_size,
            find_state: Arc::new(FairMutex::new(FindState::default())),
            find_results: FindResultStore::new(),
            cells: Vec::new(),
            cell_text: Vec::new(),
            theme,
            last_selection_rows: None,
            child_pid: 0,
            master_fd: -1,
            url_regex: RegexSearch::new(LINK_REGEX).expect("test URL regex"),
            dirty_rows: Vec::new(),
            kitty_placements: Vec::new(),
            kitty_images: Vec::new(),
            last_kitty_damage_revision: 0,
            snapshot_cache: SnapshotCache::new(),
            frame_busy_count: 0,
            frame_handoff: FrameHandoff::new(),
            exited: false,
        };
        {
            let mut term = terminal.term.lock_unfair();
            let mut parser: Processor = Processor::new();
            parser.advance(&mut *term, b"one\r\ntwo\r\nthree\r\nfour");
            term.reset_damage();
            parser.advance(&mut *term, b"\x1b[2;1HX");
        }
        terminal
    }

    #[test]
    fn clear_queues_find_invalidation_before_following_form_feed() {
        let mut terminal = test_terminal_with_damage();
        let (sender, receiver) = std::sync::mpsc::channel();
        let poller = Arc::new(Poller::new().expect("test poller should be available"));
        terminal.notifier = GraphicsNotifier(GraphicsEventLoopSender::for_test(sender, poller));
        let handle = &mut terminal as *mut KeroTerminal;

        unsafe { kero_alacritty_clear(handle) };
        let form_feed = [b'\x0c'];
        unsafe { kero_alacritty_write(handle, form_feed.as_ptr(), form_feed.len()) };

        assert!(matches!(
            receiver.recv().unwrap(),
            GraphicsMsg::InvalidateFind
        ));
        assert!(matches!(
            receiver.recv().unwrap(),
            GraphicsMsg::UserInput(bytes) if bytes.as_ref() == form_feed
        ));
    }

    #[test]
    fn clear_carries_preinvalidated_find_generation() {
        let mut terminal = test_terminal_with_damage();
        {
            let mut term = terminal.term.lock();
            let mut find_state = terminal.find_state.lock();
            let result = apply_find_message(
                &mut term,
                &mut find_state,
                FindMessage::Begin {
                    generation: 70,
                    needle: "two".to_owned(),
                },
            );
            assert_eq!(result.total, 1);
            terminal.find_results.publish(
                result.generation,
                result.kind,
                result.total,
                result.selected,
            );
        }
        let (sender, receiver) = std::sync::mpsc::channel();
        let poller = Arc::new(Poller::new().expect("test poller should be available"));
        terminal.notifier = GraphicsNotifier(GraphicsEventLoopSender::for_test(sender, poller));
        let handle = &mut terminal as *mut KeroTerminal;

        unsafe { kero_alacritty_clear(handle) };

        assert!(matches!(
            receiver.recv().unwrap(),
            GraphicsMsg::InvalidateFindWithGeneration(70)
        ));
    }

    #[test]
    fn resize_queues_barrier_before_following_find_step() {
        let mut terminal = test_terminal_with_damage();
        let (sender, receiver) = std::sync::mpsc::channel();
        let poller = Arc::new(Poller::new().expect("test poller should be available"));
        terminal.notifier = GraphicsNotifier(GraphicsEventLoopSender::for_test(sender, poller));
        let handle = &mut terminal as *mut KeroTerminal;

        unsafe { kero_alacritty_resize(handle, 80, 5, 2, 3) };
        assert!(unsafe { kero_alacritty_find_step_async(handle, true, 7) });

        match receiver.recv().unwrap() {
            GraphicsMsg::Resize(size) => {
                assert_eq!(size.num_cols, 80);
                assert_eq!(size.num_lines, 5);
                assert_eq!(size.cell_width, 2);
                assert_eq!(size.cell_height, 3);
            }
            message => panic!("expected Resize barrier, got {message:?}"),
        }
        assert!(matches!(
            receiver.recv().unwrap(),
            GraphicsMsg::Find(FindMessage::Step {
                generation: 7,
                forward: true,
            })
        ));
    }

    #[test]
    fn resize_carries_preinvalidated_find_generation_before_barrier() {
        let mut terminal = test_terminal_with_damage();
        {
            let mut term = terminal.term.lock();
            let mut find_state = terminal.find_state.lock();
            let result = apply_find_message(
                &mut term,
                &mut find_state,
                FindMessage::Begin {
                    generation: 71,
                    needle: "two".to_owned(),
                },
            );
            assert_eq!(result.total, 1);
            terminal.find_results.publish(
                result.generation,
                result.kind,
                result.total,
                result.selected,
            );
        }
        let (sender, receiver) = std::sync::mpsc::channel();
        let poller = Arc::new(Poller::new().expect("test poller should be available"));
        terminal.notifier = GraphicsNotifier(GraphicsEventLoopSender::for_test(sender, poller));
        let handle = &mut terminal as *mut KeroTerminal;

        unsafe { kero_alacritty_resize(handle, 80, 5, 2, 3) };

        assert!(matches!(
            receiver.recv().unwrap(),
            GraphicsMsg::InvalidateFindWithGeneration(71)
        ));
        assert!(matches!(
            receiver.recv().unwrap(),
            GraphicsMsg::Resize(WindowSize {
                num_cols: 80,
                num_lines: 5,
                cell_width: 2,
                cell_height: 3,
            })
        ));
    }

    #[test]
    fn free_waits_for_event_loop_worker_before_returning() {
        let mut terminal = test_terminal_with_damage();
        let (entered_sender, entered_receiver) = std::sync::mpsc::channel();
        let (release_sender, release_receiver) = std::sync::mpsc::channel();
        let worker_exited = Arc::new(std::sync::atomic::AtomicU32::new(0));
        let worker_exited_clone = worker_exited.clone();

        terminal.event_loop = Some(std::thread::spawn(move || {
            entered_sender.send(()).expect("test worker entered");
            release_receiver.recv().expect("test worker release signal");
            worker_exited_clone.fetch_add(1, Ordering::SeqCst);
        }));
        let handle = Box::into_raw(Box::new(terminal));
        entered_receiver
            .recv_timeout(Duration::from_secs(1))
            .expect("test worker should start");

        let (freed_sender, freed_receiver) = std::sync::mpsc::channel();
        let handle_bits = handle as usize;
        let free_thread = std::thread::spawn(move || {
            unsafe { kero_alacritty_free(handle_bits as *mut KeroTerminal) };
            freed_sender.send(()).expect("free completion signal");
        });

        let returned_before_worker_release = freed_receiver
            .recv_timeout(Duration::from_millis(100))
            .is_ok();
        release_sender.send(()).expect("release test worker");
        freed_receiver
            .recv_timeout(Duration::from_secs(1))
            .expect("free should return after the worker exits");
        free_thread.join().expect("free thread should join");

        assert!(!returned_before_worker_release);
        assert_eq!(worker_exited.load(Ordering::SeqCst), 1);
    }

    fn damage_signature<L: EventListener>(term: &mut Term<L>) -> (u32, usize) {
        match term.damage() {
            TermDamage::Full => (KERO_DAMAGE_FULL, 0),
            TermDamage::Partial(iter) => (KERO_DAMAGE_PARTIAL, iter.count()),
        }
    }

    #[test]
    fn frame_metrics_start_empty_and_have_a_stable_shape() {
        let frame = empty_frame();
        assert_eq!(frame.kind, KERO_FRAME_SKIP);
        assert_eq!(frame.busy_count, 0);
        assert_eq!(frame.packed_rows, 0);
        assert_eq!(frame.kitty.placements_len, 0);
    }

    #[test]
    fn try_snapshot_rejects_null_handle_without_touching_output() {
        let mut out = empty_snapshot();
        out.columns = 7;
        let before = out.columns;

        assert!(!unsafe { kero_alacritty_try_snapshot(std::ptr::null_mut(), &mut out) });
        assert_eq!(out.columns, before);
    }

    #[test]
    fn frame_kitty_snapshot_from_empty_store_is_empty() {
        let term = parse(b"");
        let graphics = KittyGraphicsStore::default();
        let mut placements = Vec::new();
        let mut images = Vec::new();
        let mut out = empty_kitty_snapshot();

        fill_kitty_snapshot(&mut placements, &mut images, &graphics, &term, &mut out);

        assert_eq!(out.revision, 0);
        assert!(out.placements.is_null());
        assert_eq!(out.placements_len, 0);
    }

    #[test]
    fn parser_full_damage_is_not_hidden_by_host_scroll() {
        assert!(should_repack_all(KERO_FRAME_FULL, true, false, false));
        assert!(should_repack_all(KERO_FRAME_FULL, false, true, true));
        // Partial damage before a host scroll invalidates only those row ids;
        // the remaining cached rows can still be reused.
        assert!(!should_repack_all(KERO_FRAME_FULL, false, true, false));
        assert!(should_repack_all(KERO_FRAME_FULL, false, false, false));
    }

    #[test]
    fn parser_partial_rows_are_removed_before_host_scroll_reuse() {
        let mut cache = SnapshotCache::new();
        for id in 0..5 {
            cache.rows.insert(id, Vec::new());
        }

        invalidate_pre_host_rows(&mut cache, 5, 0, 3, &[1]);

        assert!(cache.rows.contains_key(&2));
        assert!(!cache.rows.contains_key(&3));
        assert!(cache.rows.contains_key(&4));
    }

    #[test]
    fn pending_target_delta_is_saturated_to_scroll_api_range() {
        assert_eq!(target_scroll_delta(i64::MAX, 0), Some(i32::MAX));
        assert_eq!(target_scroll_delta(0, i64::MAX as usize), Some(i32::MIN));
        assert_eq!(target_scroll_delta(-1, 0), None);
    }

    struct SnapshotState {
        cells: Vec<KeroCell>,
        cell_text: Vec<u8>,
        cache: SnapshotCache,
        out: KeroSnapshot,
    }

    impl SnapshotState {
        fn new() -> Self {
            Self {
                cells: Vec::new(),
                cell_text: Vec::new(),
                cache: SnapshotCache::new(),
                out: empty_snapshot(),
            }
        }

        fn fill(&mut self, term: &Term<VoidListener>, dirty_rows: Option<&[usize]>) -> usize {
            fill_snapshot(
                &mut self.cells,
                &mut self.cell_text,
                &mut self.cache,
                &theme(),
                term,
                dirty_rows,
                false,
                &mut self.out,
            )
        }

        fn fill_repack(&mut self, term: &Term<VoidListener>) -> usize {
            fill_snapshot(
                &mut self.cells,
                &mut self.cell_text,
                &mut self.cache,
                &theme(),
                term,
                None,
                true,
                &mut self.out,
            )
        }

        fn ch(&self, row: usize, column: usize) -> char {
            char::from_u32(self.cells[row * self.out.columns + column].ch).unwrap()
        }
    }

    #[test]
    fn snapshot_full_refill_writes_every_cell() {
        let term = parse(b"Hi");
        let mut snap = SnapshotState::new();
        snap.fill(&term, None);

        assert_eq!(snap.cells.len(), 40 * 3);
        assert_eq!(snap.out.columns, 40);
        assert_eq!(snap.out.rows, 3);
        assert_eq!(snap.ch(0, 0), 'H');
        assert_eq!(snap.ch(0, 1), 'i');
        assert_eq!(snap.ch(0, 2), ' ');
        assert_eq!(snap.ch(1, 0), ' ');
        assert_eq!(snap.out.cursor_line, 0);
        assert_eq!(snap.out.cursor_column, 2);
        assert_eq!(snap.out.ime_cursor_line, 0);
        assert_eq!(snap.out.ime_cursor_column, 2);
    }

    #[test]
    fn hidden_cursor_keeps_ime_anchor_only_in_live_viewport() {
        let mut term = parse(b"one\r\ntwo\r\nthree\r\nfour");
        write_vt(&mut term, b"\x1b[?25l");
        let mut snap = SnapshotState::new();
        snap.fill(&term, None);

        assert_eq!(snap.out.cursor_line, -1);
        assert_eq!(snap.out.cursor_column, -1);
        assert_eq!(snap.out.ime_cursor_line, 2);
        assert_eq!(snap.out.ime_cursor_column, 4);

        term.scroll_display(Scroll::Delta(1));
        snap.fill(&term, Some(&[]));

        assert_eq!(snap.out.ime_cursor_line, -1);
        assert_eq!(snap.out.ime_cursor_column, -1);
    }

    #[test]
    fn snapshot_reports_actual_rows_packed() {
        let term = parse(b"Hi");
        let mut snap = SnapshotState::new();
        assert_eq!(snap.fill(&term, None), 3);
        assert_eq!(snap.fill(&term, Some(&[])), 0);
    }

    #[test]
    fn frame_try_lock_reports_busy_without_waiting() {
        let mutex = FairMutex::new(());
        let _held = mutex.lock_unfair();
        assert!(try_frame_lock(&mutex).is_none());
    }

    #[test]
    fn frame_try_lock_pair_fails_when_either_frame_lock_is_held() {
        let graphics = FairMutex::new(());
        let term = FairMutex::new(());
        let handoff = FrameHandoff::new();

        let held_graphics = graphics.lock_unfair();
        assert!(try_frame_locks(&handoff, &graphics, &term).is_none());
        drop(held_graphics);

        let held_term = term.lock_unfair();
        assert!(try_frame_locks(&handoff, &graphics, &term).is_none());
        drop(held_term);

        assert!(try_frame_locks(&handoff, &graphics, &term).is_some());
    }

    #[test]
    fn ui_try_lock_reports_busy_without_waiting() {
        let mutex = FairMutex::new(());
        let _held = mutex.lock_unfair();

        assert!(try_ui_lock(&mutex).is_none());
    }

    #[test]
    fn ui_ffi_null_handles_return_false_or_zero() {
        let null = std::ptr::null_mut();
        assert!(!unsafe { kero_alacritty_selection_start(null, 0, 0, 0, false) });
        assert!(!unsafe { kero_alacritty_selection_update(null, 0, 0, false) });
        assert!(!unsafe { kero_alacritty_select_all(null) });
        assert!(!unsafe { kero_alacritty_clear_selection(null) });
        assert_eq!(
            unsafe { kero_alacritty_selection_state(null) },
            KERO_SELECTION_BUSY
        );
        unsafe { kero_alacritty_clear_selection_async(null) };
        assert_eq!(
            unsafe {
                kero_alacritty_url_at(
                    null,
                    0,
                    0,
                    std::ptr::null_mut::<KeroURLRange>(),
                    std::ptr::null_mut::<u8>(),
                    0,
                )
            },
            0
        );
    }

    #[test]
    fn async_find_api_rejects_null_without_touching_result() {
        let null = std::ptr::null_mut();
        let mut result = KeroFindResult {
            generation: 99,
            kind: KERO_FIND_RESULT_STEP,
            total: 7,
            selected: 3,
        };

        assert!(!unsafe { kero_alacritty_find_poll(null, &mut result) });
        assert_eq!(result.generation, 99);
        assert!(!unsafe { kero_alacritty_find_begin_async(null, std::ptr::null(), 1) });
        assert!(!unsafe { kero_alacritty_find_step_async(null, true, 2) });
        assert!(!unsafe { kero_alacritty_find_end_async(null, 3) });
    }

    #[test]
    fn selection_reads_and_select_all_report_busy_without_waiting() {
        let mut terminal = test_terminal_with_damage();
        let handle = &mut terminal as *mut KeroTerminal;
        let term_mutex = Arc::clone(&terminal.term);
        let held_term = term_mutex.lock_unfair();

        assert_eq!(
            unsafe { kero_alacritty_selection_state(handle) },
            KERO_SELECTION_BUSY
        );
        assert!(!unsafe { kero_alacritty_has_selection(handle) });
        let mut buffer = [0xA5; 4];
        assert_eq!(
            unsafe { kero_alacritty_selection_text(handle, buffer.as_mut_ptr(), buffer.len()) },
            0
        );
        assert_eq!(buffer, [0xA5; 4]);
        assert!(!unsafe { kero_alacritty_select_all(handle) });

        drop(held_term);
        assert_eq!(
            unsafe { kero_alacritty_selection_state(handle) },
            KERO_SELECTION_EMPTY
        );
        assert!(unsafe { kero_alacritty_select_all(handle) });
        assert_eq!(
            unsafe { kero_alacritty_selection_state(handle) },
            KERO_SELECTION_PRESENT
        );
    }

    #[test]
    fn begin_frame_busy_preserves_handle_state_for_both_locks() {
        let mut terminal = test_terminal_with_damage();
        add_test_kitty_placement(&terminal);
        let handle = &mut terminal as *mut KeroTerminal;
        let mut frame = empty_frame();
        unsafe {
            kero_alacritty_begin_frame(handle, 0, -1, true, false, &mut frame);
        }
        assert_ne!(frame.kind, KERO_FRAME_BUSY);
        assert!(!frame.snapshot.cells.is_null());
        assert!(frame.snapshot.columns > 0);
        assert!(frame.snapshot.rows > 0);
        assert!(!frame.snapshot.row_ids.is_null());
        assert!(frame.kitty.placements_len > 0);
        assert!(!frame.kitty.placements.is_null());
        let before_snapshot = snapshot_fields(&frame.snapshot);
        let before_kitty = kitty_fields(&frame.kitty);

        {
            let term_mutex = Arc::clone(&terminal.term);
            let mut term = term_mutex.lock_unfair();
            let mut parser: Processor = Processor::new();
            parser.advance(&mut *term, b"\x1b[2;1HY");
        }
        let (before_offset, before_damage) = {
            let term_mutex = Arc::clone(&terminal.term);
            let mut term = term_mutex.lock_unfair();
            (term.grid().display_offset(), damage_signature(&mut term))
        };

        let graphics_mutex = Arc::clone(&terminal.kitty_graphics);
        let held_graphics = graphics_mutex.lock_unfair();
        unsafe {
            kero_alacritty_begin_frame(handle, 1, -1, false, false, &mut frame);
        }
        assert_eq!(frame.kind, KERO_FRAME_BUSY);
        assert_eq!(snapshot_fields(&frame.snapshot), before_snapshot);
        assert_eq!(kitty_fields(&frame.kitty), before_kitty);
        drop(held_graphics);

        {
            let term_mutex = Arc::clone(&terminal.term);
            let mut term = term_mutex.lock_unfair();
            assert_eq!(term.grid().display_offset(), before_offset);
            assert_eq!(damage_signature(&mut term), before_damage);
        }

        let term_mutex = Arc::clone(&terminal.term);
        let held_term = term_mutex.lock_unfair();
        unsafe {
            kero_alacritty_begin_frame(handle, 1, -1, false, false, &mut frame);
        }
        assert_eq!(frame.kind, KERO_FRAME_BUSY);
        assert_eq!(snapshot_fields(&frame.snapshot), before_snapshot);
        assert_eq!(kitty_fields(&frame.kitty), before_kitty);
        drop(held_term);

        {
            let mut term = term_mutex.lock_unfair();
            assert_eq!(term.grid().display_offset(), before_offset);
            assert_eq!(damage_signature(&mut term), before_damage);
        }

        unsafe {
            kero_alacritty_begin_frame(handle, 1, -1, false, false, &mut frame);
        }
        assert_eq!(frame.kind, KERO_FRAME_FULL);
        let mut term = term_mutex.lock_unfair();
        assert_eq!(term.grid().display_offset(), before_offset + 1);
        term.reset_damage();
        assert!(!matches!(term.damage(), TermDamage::Full));
    }

    #[test]
    fn snapshot_row_limited_refill_updates_only_that_row() {
        let mut term = parse(b"AAA\r\nBBB\r\nCCC");
        let mut snap = SnapshotState::new();
        snap.fill(&term, None);
        assert_eq!(snap.ch(0, 0), 'A');
        assert_eq!(snap.ch(1, 0), 'B');
        assert_eq!(snap.ch(2, 0), 'C');

        write_vt(&mut term, b"\x1b[2;1HXXX");
        snap.fill(&term, Some(&[1]));
        assert_eq!(snap.ch(0, 0), 'A');
        assert_eq!(snap.ch(1, 0), 'X');
        assert_eq!(snap.ch(1, 1), 'X');
        assert_eq!(snap.ch(1, 2), 'X');
        assert_eq!(snap.ch(2, 0), 'C');
    }

    #[test]
    fn snapshot_empty_dirty_rows_leave_cells_and_refresh_cursor() {
        let mut term = parse(b"Hi");
        let mut snap = SnapshotState::new();
        snap.fill(&term, None);
        let before = snap.cells.clone();
        let before_column = snap.out.cursor_column;

        write_vt(&mut term, b"\x1b[2;1HZ\x1b[1;10H");
        snap.fill(&term, Some(&[]));
        assert_eq!(snap.cells, before);
        assert_eq!(snap.ch(1, 0), ' ');
        assert_eq!(snap.out.cursor_line, 0);
        assert_eq!(snap.out.cursor_column, 9);
        assert_eq!(snap.out.ime_cursor_line, 0);
        assert_eq!(snap.out.ime_cursor_column, 9);
        assert_ne!(snap.out.cursor_column, before_column);
    }

    #[test]
    fn snapshot_display_offset_change_full_refills() {
        let mut term = parse(b"one\r\ntwo\r\nthree\r\nfour");
        let mut snap = SnapshotState::new();
        snap.fill(&term, None);
        assert_eq!(snap.out.display_offset, 0);
        assert_eq!(snap.ch(0, 0), 't');

        term.scroll_display(Scroll::Delta(1));
        snap.fill(&term, Some(&[]));
        assert_eq!(snap.out.display_offset, 1);
        assert_eq!(snap.ch(0, 0), 'o');
        assert_eq!(snap.ch(1, 0), 't');
    }

    #[test]
    fn snapshot_resize_full_refills() {
        let mut term = parse(b"Hi\r\nYo");
        let mut snap = SnapshotState::new();
        snap.fill(&term, None);
        assert_eq!(snap.cells.len(), 40 * 3);

        term.resize(TermSize {
            columns: 40,
            screen_lines: 5,
        });
        snap.fill(&term, Some(&[0]));
        assert_eq!(snap.cells.len(), 40 * 5);
        assert_eq!(snap.out.rows, 5);
        assert_eq!(snap.ch(0, 0), 'H');
        assert_eq!(snap.ch(1, 0), 'Y');
        assert_eq!(snap.ch(4, 0), ' ');
    }

    #[test]
    fn snapshot_arena_reset_refills_rows_with_old_text_offsets() {
        let mut term = parse("A\u{301}\r\nB\u{302}".as_bytes());
        let mut snap = SnapshotState::new();
        snap.fill(&term, None);

        // Force the same arena-bound invalidation used in production, then
        // report only the second row as dirty. Every existing text offset must
        // still point into the new arena returned by this call.
        snap.cell_text.resize(CELL_TEXT_LIMIT + 1, 0);
        write_vt(&mut term, b"\x1b[2;1HX");
        snap.fill(&term, Some(&[1]));

        let cell = snap.cells[0];
        let start = cell.text_offset as usize;
        let end = start + cell.text_len as usize;
        assert!(end <= snap.cell_text.len());
        assert_eq!(&snap.cell_text[start..end], "A\u{301}".as_bytes());
    }
}

/// One locked region per frame: applies pending host scroll, drains the
/// emulator's damage, and fills the snapshot the host needs to draw.
///
/// The lock structure is the point. The PTY parse thread holds the term mutex
/// in multi-millisecond bursts under heavy output, and the host used to
/// acquire it three ways per frame — once per scroll event
/// (`kero_alacritty_scroll` at trackpad rate), once for damage, once for the
/// snapshot — each an unbounded wait behind the parser. Scroll intent now
/// accumulates on the host (`pending_scroll` line delta, or
/// `pending_target` absolute display offset, which wins when both are set)
/// and everything happens inside this single critical section after one
/// non-blocking attempt to acquire both frame locks.
///
/// A wakeup only means bytes arrived, not that the grid moved: a heartbeat, a
/// cursor-position query, or output that overwrites a cell with identical
/// contents all wake the host for nothing. And when something *has* changed it
/// is usually one row — a prompt redraw, a cursor blink — so rebuilding every
/// cell's draw instance adds work without changing the frame.
///
/// Verdict: `force_full` (host-side changes the emulator cannot see — resize,
/// theme, selection, focus) or emulator FULL damage yields FULL and a full
/// snapshot walk; PARTIAL damage yields DIRTY and refills only those rows;
/// otherwise `cursor_only` yields CURSOR (cursor fields, cells untouched);
/// otherwise SKIP and the host drops the frame.
///
/// Rows rather than the full spans: the renderer caches per row and columns
/// would not let it skip any more work, so carrying them would only widen the
/// FFI. The row list belongs to the handle and is valid until the next call.
///
fn try_frame_lock<T>(mutex: &FairMutex<T>) -> Option<impl std::ops::DerefMut<Target = T> + '_> {
    mutex.try_lock_unfair()
}

fn try_ui_lock<T>(mutex: &FairMutex<T>) -> Option<impl std::ops::DerefMut<Target = T> + '_> {
    mutex.try_lock_unfair()
}

fn try_frame_locks<'a, T, U>(
    handoff: &FrameHandoff,
    graphics_mutex: &'a FairMutex<T>,
    term_mutex: &'a FairMutex<U>,
) -> Option<(
    impl std::ops::DerefMut<Target = T> + 'a,
    impl std::ops::DerefMut<Target = U> + 'a,
)> {
    let mut turn = handoff.try_reserve_frame_lock()?;
    let graphics = try_frame_lock(graphics_mutex)?;
    let term = try_frame_lock(term_mutex)?;
    // Keep the handoff turn through the whole frame. This prevents a worker
    // from claiming the turn between the non-blocking lock attempts and the
    // frame guards' drop, while failed attempts release it via `Drop`.
    turn.hold_for_frame();
    Some((graphics, term))
}

fn target_scroll_delta(target: i64, current: usize) -> Option<i32> {
    let target = (target >= 0).then_some(target)?;
    let current = i64::try_from(current).unwrap_or(i64::MAX);
    let delta = target.saturating_sub(current);
    Some(delta.clamp(i32::MIN as i64, i32::MAX as i64) as i32)
}

/// Completes a successful frame handoff after its frame locks leave scope.
/// BUSY disarms the guard so a retry leaves the worker turn unchanged.
struct FrameHandoffCompletion {
    handoff: FrameHandoff,
    finish_on_drop: bool,
}

impl FrameHandoffCompletion {
    fn new(handoff: FrameHandoff) -> Self {
        Self {
            handoff,
            finish_on_drop: true,
        }
    }

    fn leave_requested(&mut self) {
        self.finish_on_drop = false;
    }
}

impl Drop for FrameHandoffCompletion {
    fn drop(&mut self) {
        if self.finish_on_drop {
            self.handoff.finish();
        }
    }
}

/// Signals that the host has queued a display frame. The frame path tries both
/// locks without waiting; the PTY worker continues parsing, and an already
/// waiting worker keeps the next terminal-lock turn after a frame completes.
///
/// # Safety
/// `handle` must be null or point to a live `KeroTerminal`.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_request_frame(handle: *mut KeroTerminal) {
    if let Some(terminal) = handle.as_ref() {
        terminal.frame_handoff.request();
    }
}

/// Cancels a queued frame handoff when the host no longer intends to render.
///
/// # Safety
/// `handle` must be null or point to a live `KeroTerminal`.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_cancel_frame_request(handle: *mut KeroTerminal) {
    if let Some(terminal) = handle.as_ref() {
        terminal.frame_handoff.finish();
    }
}

/// # Safety
/// `handle` must be live and `out` a valid `KeroFrame`.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_begin_frame(
    handle: *mut KeroTerminal,
    pending_scroll: i32,
    pending_target: i64,
    force_full: bool,
    cursor_only: bool,
    out: *mut KeroFrame,
) {
    if handle.is_null() || out.is_null() {
        return;
    }
    let terminal = &mut *handle;
    terminal.frame_handoff.request();
    // Declared before the lock guards, so Rust drops the locks first and only
    // then wakes the PTY worker on every successful return path.
    let mut handoff_completion = FrameHandoffCompletion::new(terminal.frame_handoff.clone());
    terminal.dirty_rows.clear();
    let theme = terminal.theme;
    let lock_started = Instant::now();

    let Some((graphics, mut term)) = try_frame_locks(
        &terminal.frame_handoff,
        &terminal.kitty_graphics,
        &terminal.term,
    ) else {
        handoff_completion.leave_requested();
        terminal.frame_busy_count = terminal.frame_busy_count.saturating_add(1);
        (*out).kind = KERO_FRAME_BUSY;
        (*out).dirty_rows = std::ptr::null();
        (*out).dirty_rows_len = 0;
        (*out).busy_count = terminal.frame_busy_count;
        (*out).lock_wait_ns = lock_started.elapsed().as_nanos() as u64;
        (*out).snapshot_ns = 0;
        (*out).build_ns = 0;
        (*out).packed_rows = 0;
        return;
    };
    let lock_wait_ns = lock_started.elapsed().as_nanos() as u64;
    let snapshot_started = Instant::now();

    // Read damage before applying host scrolling. Alacritty reports the
    // scroll itself as FULL, which must not hide a parser FULL from the same
    // frame. For parser PARTIAL, remember the old viewport row ids; a host
    // scroll changes their viewport positions, so those cached rows cannot be
    // reused at their old absolute ids.
    let screen_lines = term.screen_lines();
    let pre_host_total_lines = term.total_lines();
    let pre_host_offset = term.grid().display_offset();
    let parser_damage_full = match term.damage() {
        TermDamage::Full => true,
        TermDamage::Partial(iter) => {
            for bounds in iter {
                terminal.dirty_rows.push(bounds.line);
            }
            false
        }
    };

    // Host scroll first: scroll_display marks FULL damage whenever the offset
    // moves. `parser_damage_full` above distinguishes that host-only FULL from
    // a parser FULL that must repack every row.
    let offset_before = term.grid().display_offset();
    if let Some(delta) = target_scroll_delta(pending_target, offset_before) {
        if delta != 0 {
            term.scroll_display(Scroll::Delta(delta));
        }
    } else if pending_scroll != 0 {
        term.scroll_display(Scroll::Delta(pending_scroll));
    }
    let host_scrolled = term.grid().display_offset() != offset_before;

    if host_scrolled && !parser_damage_full {
        invalidate_pre_host_rows(
            &mut terminal.snapshot_cache,
            pre_host_total_lines,
            pre_host_offset,
            screen_lines,
            &terminal.dirty_rows,
        );
    }
    terminal.dirty_rows.clear();

    let mut kind = match term.damage() {
        TermDamage::Full => KERO_DAMAGE_FULL,
        TermDamage::Partial(iter) => {
            for bounds in iter {
                terminal.dirty_rows.push(bounds.line);
            }
            if terminal.dirty_rows.is_empty() {
                KERO_DAMAGE_NONE
            } else {
                KERO_DAMAGE_PARTIAL
            }
        }
    };
    term.reset_damage();
    let selection_rows = selection_viewport_row_range(&term);
    let graphics_revision = graphics.revision;
    if graphics_revision != terminal.last_kitty_damage_revision {
        terminal.last_kitty_damage_revision = graphics_revision;
        kind = KERO_DAMAGE_FULL;
        terminal.dirty_rows.clear();
    }

    // Selection is not in Term::damage. Union the previous and current
    // selected viewport rows so a drag can rebuild those lines only.
    if kind != KERO_DAMAGE_FULL {
        let previous = terminal.last_selection_rows;
        if previous != selection_rows {
            if let Some(range) = previous {
                union_viewport_rows(&mut terminal.dirty_rows, range, screen_lines);
            }
            if let Some(range) = selection_rows {
                union_viewport_rows(&mut terminal.dirty_rows, range, screen_lines);
            }
            if kind == KERO_DAMAGE_NONE && !terminal.dirty_rows.is_empty() {
                kind = KERO_DAMAGE_PARTIAL;
            }
        }
    }
    terminal.last_selection_rows = selection_rows;

    let frame_kind = frame_verdict(force_full, cursor_only, kind);
    if frame_kind == KERO_FRAME_SKIP {
        (*out).kind = KERO_FRAME_SKIP;
        (*out).dirty_rows = terminal.dirty_rows.as_ptr();
        (*out).dirty_rows_len = terminal.dirty_rows.len();
        (*out).busy_count = terminal.frame_busy_count;
        (*out).lock_wait_ns = lock_wait_ns;
        (*out).snapshot_ns = snapshot_started.elapsed().as_nanos() as u64;
        (*out).build_ns = 0;
        (*out).packed_rows = 0;
        return;
    }
    let snapshot_ns = snapshot_started.elapsed().as_nanos() as u64;
    let request: Option<&[usize]> = match frame_kind {
        KERO_FRAME_FULL => None,
        KERO_FRAME_DIRTY => Some(terminal.dirty_rows.as_slice()),
        _ => Some(&[]),
    };

    // FULL damage the host's own scroll did not cause means every row may
    // have changed in place (a mode flip repaint), which no id shift covers.
    // Host-forced frames (theme) get the same treatment.
    let repack_all = should_repack_all(frame_kind, force_full, host_scrolled, parser_damage_full);
    let build_started = Instant::now();
    let packed_rows = fill_snapshot(
        &mut terminal.cells,
        &mut terminal.cell_text,
        &mut terminal.snapshot_cache,
        &theme,
        &term,
        request,
        repack_all,
        &mut (*out).snapshot,
    );
    fill_kitty_snapshot(
        &mut terminal.kitty_placements,
        &mut terminal.kitty_images,
        &graphics,
        &term,
        &mut (*out).kitty,
    );
    let build_ns = build_started.elapsed().as_nanos() as u64;

    (*out).kind = frame_kind;
    (*out).dirty_rows = terminal.dirty_rows.as_ptr();
    (*out).dirty_rows_len = terminal.dirty_rows.len();
    (*out).busy_count = terminal.frame_busy_count;
    (*out).lock_wait_ns = lock_wait_ns;
    (*out).snapshot_ns = snapshot_ns;
    (*out).build_ns = build_ns;
    (*out).packed_rows = packed_rows;
}

/// The verdict half of `kero_alacritty_begin_frame`: how to refill the
/// snapshot given the host's flags and the drained emulator damage.
fn should_repack_all(
    frame_kind: u32,
    force_full: bool,
    host_scrolled: bool,
    parser_damage_full: bool,
) -> bool {
    frame_kind == KERO_FRAME_FULL && (force_full || !host_scrolled || parser_damage_full)
}

fn invalidate_pre_host_rows(
    cache: &mut SnapshotCache,
    total_lines: usize,
    display_offset: usize,
    screen_lines: usize,
    rows: &[usize],
) {
    let viewport_first = total_lines.saturating_sub(display_offset + screen_lines);
    for &row in rows {
        if row < screen_lines {
            cache.rows.remove(&(viewport_first + row));
        }
    }
}

fn frame_verdict(force_full: bool, cursor_only: bool, damage: u32) -> u32 {
    if force_full || damage == KERO_DAMAGE_FULL {
        KERO_FRAME_FULL
    } else if damage == KERO_DAMAGE_PARTIAL {
        KERO_FRAME_DIRTY
    } else if cursor_only {
        KERO_FRAME_CURSOR
    } else {
        KERO_FRAME_SKIP
    }
}

fn selection_viewport_row_range<L: EventListener>(term: &Term<L>) -> Option<(i32, i32)> {
    let range = term
        .selection
        .as_ref()
        .and_then(|selection| selection.to_range(term))?;
    let offset = term.grid().display_offset() as i32;
    Some((range.start.line.0 + offset, range.end.line.0 + offset))
}

fn union_viewport_rows(rows: &mut Vec<usize>, range: (i32, i32), screen_lines: usize) {
    if screen_lines == 0 {
        return;
    }
    let first = range.0.max(0) as usize;
    if first >= screen_lines {
        return;
    }
    let last = (range.1.max(0) as usize).min(screen_lines - 1);
    if last < first {
        return;
    }
    for row in first..=last {
        if !rows.contains(&row) {
            rows.push(row);
        }
    }
}

fn kero_cell_flags(cell: &Cell, selected: bool) -> u16 {
    let mut flags = 0u16;
    let source = cell.flags;
    if source.contains(Flags::INVERSE) {
        flags |= KERO_CELL_INVERSE;
    }
    if source.contains(Flags::BOLD) {
        flags |= KERO_CELL_BOLD;
    }
    if source.contains(Flags::ITALIC) {
        flags |= KERO_CELL_ITALIC;
    }
    if source.intersects(Flags::ALL_UNDERLINES) {
        flags |= KERO_CELL_UNDERLINE;
    }
    if source.contains(Flags::STRIKEOUT) {
        flags |= KERO_CELL_STRIKEOUT;
    }
    if source.contains(Flags::DIM) {
        flags |= KERO_CELL_DIM;
    }
    if source.contains(Flags::HIDDEN) {
        flags |= KERO_CELL_HIDDEN;
    }
    if source.contains(Flags::WIDE_CHAR) {
        flags |= KERO_CELL_WIDE;
    }
    if source.intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER) {
        flags |= KERO_CELL_WIDE_SPACER;
    }
    if selected {
        flags |= KERO_CELL_SELECTED;
    }
    flags
}

fn encode_cell_text(cell: &Cell, cell_text: &mut Vec<u8>) -> (u32, u16) {
    let Some(marks) = cell.zerowidth().filter(|marks| !marks.is_empty()) else {
        return (0, 0);
    };
    let offset = cell_text.len();
    let mut encoded = [0; 4];
    cell_text.extend_from_slice(cell.c.encode_utf8(&mut encoded).as_bytes());
    for mark in marks {
        cell_text.extend_from_slice(mark.encode_utf8(&mut encoded).as_bytes());
    }
    let len = cell_text.len() - offset;
    if offset <= u32::MAX as usize && len <= u16::MAX as usize {
        (offset as u32, len as u16)
    } else {
        cell_text.truncate(offset);
        (0, 0)
    }
}

fn pack_kero_cell(
    cell: &Cell,
    point: Point,
    selection: Option<SelectionRange>,
    colors: &Colors,
    theme: &KeroTheme,
    cell_text: &mut Vec<u8>,
) -> KeroCell {
    let selected = selection.is_some_and(|range| range.contains(point));
    let (text_offset, text_len) = encode_cell_text(cell, cell_text);
    KeroCell {
        ch: u32::from(cell.c),
        fg: resolve(cell.fg, colors, theme),
        bg: resolve(cell.bg, colors, theme),
        text_offset,
        text_len,
        flags: kero_cell_flags(cell, selected),
    }
}

fn refill_viewport_rows<L, I>(
    cells: &mut [KeroCell],
    cell_text: &mut Vec<u8>,
    term: &Term<L>,
    theme: &KeroTheme,
    selection: Option<SelectionRange>,
    colors: &Colors,
    display_offset: usize,
    columns: usize,
    screen_lines: usize,
    rows: I,
) where
    L: EventListener,
    I: IntoIterator<Item = usize>,
{
    let grid = term.grid();
    let offset = display_offset as i32;
    for viewport_row in rows {
        if viewport_row >= screen_lines {
            continue;
        }
        let grid_line = Line(viewport_row as i32 - offset);
        let row = &grid[grid_line];
        let cell_offset = viewport_row * columns;
        for column in 0..columns {
            let point = Point::new(grid_line, Column(column));
            cells[cell_offset + column] = pack_kero_cell(
                &row[Column(column)],
                point,
                selection,
                colors,
                theme,
                cell_text,
            );
        }
    }
}

fn write_snapshot_out<L: EventListener>(
    out: &mut KeroSnapshot,
    cells: &[KeroCell],
    cell_text: &[u8],
    term: &Term<L>,
    theme: &KeroTheme,
    content: &RenderableContent<'_>,
    columns: usize,
    screen_lines: usize,
    background: u32,
    row_ids: &[u64],
    row_generation: u64,
) {
    let cursor = content.cursor;
    let hidden = !term.mode().contains(TermMode::SHOW_CURSOR)
        || matches!(cursor.shape, CursorShape::Hidden)
        || content.display_offset != 0;
    let (cursor_line, cursor_column) = if hidden {
        (-1, -1)
    } else {
        (cursor.point.line.0 as isize, cursor.point.column.0 as isize)
    };
    let (ime_cursor_line, ime_cursor_column) = if content.display_offset == 0
        && cursor.point.line.0 >= 0
        && (cursor.point.line.0 as usize) < screen_lines
        && cursor.point.column.0 < columns
    {
        (cursor.point.line.0 as isize, cursor.point.column.0 as isize)
    } else {
        (-1, -1)
    };

    *out = KeroSnapshot {
        cells: cells.as_ptr(),
        columns,
        rows: screen_lines,
        cursor_line,
        cursor_column,
        cursor_shape: match cursor.shape {
            CursorShape::Block => 0,
            CursorShape::Underline => 1,
            CursorShape::Beam => 2,
            CursorShape::HollowBlock => 3,
            _ => 0,
        },
        cursor_color: content.colors[NamedColor::Cursor as usize]
            .map(pack)
            .unwrap_or(theme.cursor),
        background,
        cursor_blinking: term.cursor_style().blinking,
        text: cell_text.as_ptr(),
        text_len: cell_text.len(),
        display_offset: content.display_offset,
        total_lines: term.total_lines(),
        screen_lines,
        row_ids: row_ids.as_ptr(),
        row_generation,
        ime_cursor_line,
        ime_cursor_column,
    };
}

/// Packs the visible grid into `cells`.
///
/// `None` means anything may have changed: rows whose absolute line id is
/// already in the cache are copied and only the rest are walked — a scroll
/// reveals a couple of new rows, not a new viewport. `Some(&[])` is
/// cursor-only: cells stay as they are. `Some(rows)` refills those viewport
/// rows. An empty buffer or a size change still walks every visible row.
/// `repack_all` forces that walk too, for full damage the host did not cause
/// by scrolling (a mode flip repaints every row in place).
fn fill_snapshot<L: EventListener>(
    cells: &mut Vec<KeroCell>,
    cell_text: &mut Vec<u8>,
    cache: &mut SnapshotCache,
    theme: &KeroTheme,
    term: &Term<L>,
    dirty_rows: Option<&[usize]>,
    repack_all: bool,
    out: &mut KeroSnapshot,
) -> usize {
    let columns = term.columns();
    let screen_lines = term.screen_lines();
    let background = term.colors()[NamedColor::Background as usize]
        .map(pack)
        .unwrap_or(theme.background);
    let content = term.renderable_content();
    let display_offset = content.display_offset;
    let total_lines = term.total_lines();

    // First absolute line index visible in the viewport.
    let viewport_first = total_lines.saturating_sub(display_offset + screen_lines);

    let geometry_changed = cells.len() != columns * screen_lines || cache.columns != columns;
    let selection = content.selection.map(|range| (range.start, range.end));
    let cache_reset = total_lines < cache.last_total_lines
        || selection != cache.selection
        || geometry_changed
        || repack_all
        || cell_text.len() > CELL_TEXT_LIMIT;
    if cache_reset {
        cache.generation = cache.generation.wrapping_add(1);
        cache.rows.clear();
        cell_text.clear();
    }
    cache.columns = columns;
    cache.last_total_lines = total_lines;
    cache.selection = selection;

    if geometry_changed {
        cells.clear();
        cells.resize(
            columns * screen_lines,
            KeroCell {
                ch: u32::from(' '),
                fg: theme.foreground,
                bg: background,
                text_offset: 0,
                text_len: 0,
                flags: 0,
            },
        );
    }

    cache.row_ids.clear();
    cache
        .row_ids
        .extend((0..screen_lines).map(|row| (viewport_first + row) as u64));

    // Cursor-only and partial requests are only valid while the window
    // stands still at the same size: a geometry change or a moved window
    // upgrades them, so unnamed rows never keep pre-move content.
    let window_moved = cache.last_viewport_first != viewport_first;
    let request: Option<&[usize]> = if cache_reset
        || geometry_changed
        || (window_moved && dirty_rows.is_some_and(|rows| rows.is_empty()))
    {
        None
    } else {
        dirty_rows
    };
    let mut packed_rows = 0;
    match request {
        Some(rows) if !rows.is_empty() => {
            // Combining text for dirty rows is appended. Offsets on other
            // rows stay valid; orphans are dropped on the next full walk.
            refill_viewport_rows(
                cells,
                cell_text,
                term,
                theme,
                content.selection,
                content.colors,
                display_offset,
                columns,
                screen_lines,
                rows.iter().copied(),
            );
            packed_rows = rows.iter().filter(|&&row| row < screen_lines).count();
            for &row in rows {
                if row < screen_lines {
                    let start = row * columns;
                    cache
                        .rows
                        .insert(viewport_first + row, cells[start..start + columns].to_vec());
                }
            }
        }
        // Cursor-only: cells stay as they are.
        Some(_) => {}
        None => {
            // Pack what the cache is missing, then copy the hits in.
            let mut misses: Vec<usize> = Vec::new();
            for row in 0..screen_lines {
                if !cache.rows.contains_key(&(viewport_first + row)) {
                    misses.push(row);
                }
            }
            if !misses.is_empty() {
                refill_viewport_rows(
                    cells,
                    cell_text,
                    term,
                    theme,
                    content.selection,
                    content.colors,
                    display_offset,
                    columns,
                    screen_lines,
                    misses.iter().copied(),
                );
                packed_rows = misses.len();
                for &row in &misses {
                    let start = row * columns;
                    cache
                        .rows
                        .insert(viewport_first + row, cells[start..start + columns].to_vec());
                }
            }
            for row in 0..screen_lines {
                if misses.contains(&row) {
                    continue;
                }
                if let Some(cached) = cache.rows.get(&(viewport_first + row)) {
                    let start = row * columns;
                    cells[start..start + columns].copy_from_slice(cached);
                }
            }
        }
    }

    // Bound the map to rows near the viewport so a long scroll through
    // history cannot grow it without limit.
    if cache.rows.len() > 4 * screen_lines {
        let keep_from = viewport_first.saturating_sub(screen_lines);
        let keep_to = viewport_first + 2 * screen_lines;
        cache.rows.retain(|&id, _| id >= keep_from && id <= keep_to);
    }
    cache.last_viewport_first = viewport_first;

    write_snapshot_out(
        out,
        cells,
        cell_text,
        term,
        theme,
        &content,
        columns,
        screen_lines,
        background,
        &cache.row_ids,
        cache.generation,
    );
    packed_rows
}

/// Fills `out` with the visible grid.
///
/// Always a full refill. The cell array belongs to the handle and stays
/// valid only until the next call on it, which keeps a redraw from allocating.
/// The render loop should use `kero_alacritty_begin_frame`, which folds this
/// into its single locked region; this stands for out-of-loop readers
/// (scrollbar geometry, link hit-testing, automation reads).
///
/// # Safety
/// `handle` must be live and `out` must be a valid `KeroSnapshot`.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_snapshot(
    handle: *mut KeroTerminal,
    out: *mut KeroSnapshot,
) {
    if handle.is_null() || out.is_null() {
        return;
    }
    let terminal = &mut *handle;
    let theme = terminal.theme;
    let term = terminal.term.lock();
    // Always a full walk. Unlike begin_frame, this caller has not drained
    // the emulator's damage, so it cannot know which rows changed since its
    // last call — cache reuse would serve rows from before the change.
    fill_snapshot(
        &mut terminal.cells,
        &mut terminal.cell_text,
        &mut terminal.snapshot_cache,
        &theme,
        &term,
        None,
        true,
        &mut *out,
    );
}

/// Attempts to fill `out` with the visible grid without waiting for the PTY
/// parser. Returns false when the terminal is busy; in that case `out` is
/// unchanged.
///
/// # Safety
/// `handle` must be live and `out` must be a valid `KeroSnapshot`.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_try_snapshot(
    handle: *mut KeroTerminal,
    out: *mut KeroSnapshot,
) -> bool {
    if handle.is_null() || out.is_null() {
        return false;
    }
    let terminal = &mut *handle;
    let Some(term) = try_ui_lock(&terminal.term) else {
        return false;
    };
    let theme = terminal.theme;
    fill_snapshot(
        &mut terminal.cells,
        &mut terminal.cell_text,
        &mut terminal.snapshot_cache,
        &theme,
        &term,
        None,
        true,
        &mut *out,
    );
    true
}

// Builds the Kitty output while the caller holds the terminal and graphics
// locks. Pixel pointers remain valid while the output vectors are retained.
fn fill_kitty_snapshot<L: EventListener>(
    placements_out: &mut Vec<KeroKittyPlacement>,
    images_out: &mut Vec<Arc<[u8]>>,
    graphics: &KittyGraphicsStore,
    term: &Term<L>,
    out: &mut KeroKittySnapshot,
) {
    let history_size = term.grid().history_size();
    let display_offset = term.grid().display_offset();
    let rows = term.grid().screen_lines();
    let columns = term.grid().columns();
    let screen =
        KittyGraphicsScreen::from_alternate_screen(term.mode().contains(TermMode::ALT_SCREEN));
    let revision = graphics.revision;
    let mut placements =
        graphics
            .state
            .render_placements(history_size, display_offset, rows, columns, screen);
    placements.sort_by(|left, right| {
        left.z_index
            .cmp(&right.z_index)
            .then(left.image_id.cmp(&right.image_id))
            .then(left.placement_id.cmp(&right.placement_id))
            .then(left.placement_serial.cmp(&right.placement_serial))
    });

    placements_out.clear();
    images_out.clear();
    placements_out.reserve(placements.len());
    images_out.reserve(placements.len());
    for placement in placements {
        images_out.push(placement.rgba);
        let pixels = images_out
            .last()
            .expect("image was retained for the placement");
        placements_out.push(KeroKittyPlacement {
            placement_serial: placement.placement_serial,
            image_id: placement.image_id,
            placement_id: placement.placement_id,
            pixels: pixels.as_ptr(),
            pixels_len: pixels.len(),
            image_width: placement.image_width,
            image_height: placement.image_height,
            image_generation: placement.image_generation,
            viewport_row: placement.viewport_row,
            column: placement.column,
            source_x: placement.source_x,
            source_y: placement.source_y,
            source_width: placement.source_width,
            source_height: placement.source_height,
            display_columns: placement.display_columns,
            display_rows: placement.display_rows,
            occupied_columns: placement.occupied_columns,
            occupied_rows: placement.occupied_rows,
            x_offset: placement.x_offset,
            y_offset: placement.y_offset,
            z_index: placement.z_index,
        });
    }

    *out = KeroKittySnapshot {
        revision,
        placements: if placements_out.is_empty() {
            std::ptr::null()
        } else {
            placements_out.as_ptr()
        },
        placements_len: placements_out.len(),
    };
}

/// Fills `out` with visible Kitty image placements. Pixel pointers belong to the
/// handle and remain valid until its next FFI call.
///
/// # Safety
/// `handle` must be live and `out` must be a valid `KeroKittySnapshot`.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_kitty_snapshot(
    handle: *mut KeroTerminal,
    out: *mut KeroKittySnapshot,
) {
    if handle.is_null() || out.is_null() {
        return;
    }
    let terminal = &mut *handle;
    let term = terminal.term.lock();
    let graphics = terminal.kitty_graphics.lock();
    fill_kitty_snapshot(
        &mut terminal.kitty_placements,
        &mut terminal.kitty_images,
        &graphics,
        &term,
        &mut *out,
    );
}

/// Returns the last mode snapshot published by the parser after a terminal
/// batch. This input-path getter does not wait for the terminal mutex.
///
/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_mode(handle: *mut KeroTerminal) -> u32 {
    if handle.is_null() {
        return 0;
    }
    (*handle).mode_snapshot.load()
}

/// Marks the shell as gone so teardown does not wait on a stopped loop.
///
/// # Safety
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn kero_alacritty_mark_exited(handle: *mut KeroTerminal) {
    if handle.is_null() {
        return;
    }
    (*handle).exited = true;
}
