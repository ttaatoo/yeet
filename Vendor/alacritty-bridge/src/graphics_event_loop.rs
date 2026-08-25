//! Alacritty's PTY event loop with Kitty graphics interception at the parser
//! boundary, so image commands observe the exact live cursor and scroll state.
//!
//! The structure follows `alacritty_terminal::event_loop` and Termy's native
//! runtime loop. Termy's MIT license is in `../TERMY_LICENSE`.

use crate::{
    kitty_graphics::{
        decode_payload, prepare_upload, KittyGraphicsCommand, KittyGraphicsInterceptor,
        KittyGraphicsItem, KittyGraphicsReady, KittyGraphicsScreen, KittyGraphicsSize,
        KittyGraphicsStage, KittyGraphicsStore, PlacementContext,
    },
    kitty_graphics_tracking::{
        advance_cursor, advance_text_with_mode_snapshot, KittyGraphicsCursorTracker,
    },
};
use alacritty_terminal::{
    event::{Event, EventListener, Notify, OnResize, WindowSize},
    grid::{Dimensions, Scroll},
    index::{Boundary, Column, Direction, Line, Point, Side},
    selection::{Selection, SelectionType},
    sync::FairMutex,
    term::{
        search::{RegexIter, RegexSearch},
        Term, TermMode,
    },
    tty,
    vte::ansi,
};
use polling::{Event as PollingEvent, Events, PollMode, Poller};
use std::{
    borrow::Cow,
    collections::VecDeque,
    io::{self, ErrorKind, Read, Write},
    num::NonZeroUsize,
    sync::{
        atomic::{AtomicBool, AtomicU8, Ordering},
        mpsc::{self, Receiver, Sender, TryRecvError},
        Arc,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

const READ_BUFFER_SIZE: usize = 0x10_0000;
const MAX_LOCKED_READ: usize = u16::MAX as usize;
const PTY_READ_WRITE_TOKEN: usize = 0;
const PTY_CHILD_EVENT_TOKEN: usize = 1;
const FRAME_HANDOFF_IDLE: u8 = 0;
const FRAME_HANDOFF_REQUESTED: u8 = 1;
const LOCK_TURN_IDLE: u8 = 0;
const LOCK_TURN_WORKER: u8 = 1;
const LOCK_TURN_FRAME: u8 = 2;
const LOCK_OWNER_WORKER: u8 = 0;
const LOCK_OWNER_FRAME: u8 = 1;
const FIND_CHUNK_LINES: i32 = 64;
const FIND_MATCH_LIMIT: usize = 10_000;
const FIND_RETRY_MIN: Duration = Duration::from_millis(1);
const FIND_RETRY_MAX: Duration = Duration::from_millis(64);

struct FrameHandoffInner {
    state: AtomicU8,
    lock_turn: AtomicU8,
    worker_waiting: AtomicBool,
}

pub(crate) struct FrameLockTurn {
    inner: Arc<FrameHandoffInner>,
    owner: u8,
    held_for_frame: bool,
}

impl Drop for FrameLockTurn {
    fn drop(&mut self) {
        match self.owner {
            LOCK_OWNER_WORKER => {
                self.inner.worker_waiting.store(false, Ordering::Release);
                let _ = self.inner.lock_turn.compare_exchange(
                    LOCK_TURN_WORKER,
                    LOCK_TURN_IDLE,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                );
            }
            LOCK_OWNER_FRAME if !self.held_for_frame => {
                release_frame_turn(&self.inner);
            }
            _ => {}
        }
    }
}

impl FrameLockTurn {
    /// Keeps the frame turn reserved until `FrameHandoff::finish` runs after
    /// the frame's terminal and graphics guards are dropped.
    pub(crate) fn hold_for_frame(&mut self) {
        debug_assert_eq!(self.owner, LOCK_OWNER_FRAME);
        self.held_for_frame = true;
    }
}

fn release_frame_turn(inner: &FrameHandoffInner) {
    let next = if inner.worker_waiting.load(Ordering::Acquire) {
        LOCK_TURN_WORKER
    } else {
        LOCK_TURN_IDLE
    };
    let _ = inner.lock_turn.compare_exchange(
        LOCK_TURN_FRAME,
        next,
        Ordering::AcqRel,
        Ordering::Acquire,
    );
}

/// Coordinates a frame's non-blocking lock attempt with the PTY worker. A
/// request is only a hint to the frame path; it never parks the parser. When
/// a frame does hold the turn, a worker waiting for its next turn is promoted
/// before another frame can claim it.
#[derive(Clone)]
pub(crate) struct FrameHandoff(Arc<FrameHandoffInner>);

impl FrameHandoff {
    pub(crate) fn new() -> Self {
        Self(Arc::new(FrameHandoffInner {
            state: AtomicU8::new(FRAME_HANDOFF_IDLE),
            lock_turn: AtomicU8::new(LOCK_TURN_IDLE),
            worker_waiting: AtomicBool::new(false),
        }))
    }

    pub(crate) fn request(&self) {
        let _ = self.0.state.compare_exchange(
            FRAME_HANDOFF_IDLE,
            FRAME_HANDOFF_REQUESTED,
            Ordering::Release,
            Ordering::Relaxed,
        );
    }

    pub(crate) fn finish(&self) {
        self.0.state.store(FRAME_HANDOFF_IDLE, Ordering::Release);
        release_frame_turn(&self.0);
    }

    #[cfg(test)]
    fn lock_turn(&self) -> u8 {
        self.0.lock_turn.load(Ordering::Acquire)
    }

    #[cfg(test)]
    fn worker_waiting(&self) -> bool {
        self.0.worker_waiting.load(Ordering::Acquire)
    }

    fn reserve_worker_lock(&self) -> FrameLockTurn {
        self.0.worker_waiting.store(true, Ordering::Release);
        loop {
            match self.0.lock_turn.load(Ordering::Acquire) {
                LOCK_TURN_WORKER => {
                    return FrameLockTurn {
                        inner: Arc::clone(&self.0),
                        owner: LOCK_OWNER_WORKER,
                        held_for_frame: false,
                    };
                }
                LOCK_TURN_IDLE => {
                    if self
                        .0
                        .lock_turn
                        .compare_exchange(
                            LOCK_TURN_IDLE,
                            LOCK_TURN_WORKER,
                            Ordering::Acquire,
                            Ordering::Relaxed,
                        )
                        .is_ok()
                    {
                        return FrameLockTurn {
                            inner: Arc::clone(&self.0),
                            owner: LOCK_OWNER_WORKER,
                            held_for_frame: false,
                        };
                    }
                }
                LOCK_TURN_FRAME => thread::yield_now(),
                _ => unreachable!("invalid frame lock turn"),
            }
        }
    }

    fn try_reserve_worker_lock(&self) -> Option<FrameLockTurn> {
        self.0
            .lock_turn
            .compare_exchange(
                LOCK_TURN_IDLE,
                LOCK_TURN_WORKER,
                Ordering::Acquire,
                Ordering::Relaxed,
            )
            .ok()
            .map(|_| FrameLockTurn {
                inner: Arc::clone(&self.0),
                owner: LOCK_OWNER_WORKER,
                held_for_frame: false,
            })
    }

    pub(crate) fn try_reserve_frame_lock(&self) -> Option<FrameLockTurn> {
        self.0
            .lock_turn
            .compare_exchange(
                LOCK_TURN_IDLE,
                LOCK_TURN_FRAME,
                Ordering::Acquire,
                Ordering::Relaxed,
            )
            .ok()
            .map(|_| FrameLockTurn {
                inner: Arc::clone(&self.0),
                owner: LOCK_OWNER_FRAME,
                held_for_frame: false,
            })
    }
}

#[derive(Debug)]
pub(crate) enum GraphicsMsg {
    Input(Cow<'static, [u8]>),
    UserInput(Cow<'static, [u8]>),
    ClearSelection,
    InvalidateFind,
    InvalidateFindWithGeneration(u64),
    Find(FindMessage),
    Shutdown,
    Resize(WindowSize),
}

/// A find operation is owned by the PTY worker. The generation belongs to the
/// caller and lets it discard a result after a newer query or action replaced
/// it on the main thread.
#[derive(Debug)]
pub(crate) enum FindMessage {
    Begin { generation: u64, needle: String },
    Step { generation: u64, forward: bool },
    End { generation: u64 },
}

/// Search state retained by the PTY owner between begin and step messages.
/// `match_index` is absent until the first navigation action, so the first
/// forward action selects match zero and the first backward action selects the
/// last match.
#[derive(Default)]
pub(crate) struct FindState {
    matches: Vec<(Point, Point)>,
    match_index: Option<usize>,
    result_generation: u64,
    result_valid: bool,
    // A Begin remains active while its worker-owned scan is pending. Direct
    // grid mutations must invalidate that pending generation too; otherwise
    // its final chunk could publish coordinates from before the mutation.
    result_active: bool,
    result_invalidated: bool,
}

impl FindState {
    fn begin(&mut self, generation: u64) {
        self.matches.clear();
        self.match_index = None;
        self.result_generation = generation;
        self.result_valid = false;
        self.result_active = true;
        self.result_invalidated = false;
    }

    fn complete(&mut self, generation: u64) -> bool {
        if generation != self.result_generation || !self.result_active || self.result_invalidated {
            return false;
        }
        self.result_valid = true;
        true
    }

    pub(crate) fn invalidate(&mut self) -> Option<u64> {
        let generation = self.result_generation;
        let should_publish = self.result_active && !self.result_invalidated && generation != 0;
        self.matches.clear();
        self.match_index = None;
        if self.result_active && !self.result_invalidated {
            self.result_invalidated = true;
            self.result_valid = false;
        }
        should_publish.then_some(generation)
    }

    fn step_after_invalidation(&mut self, generation: u64) -> Option<FindCompletion> {
        if generation == 0 || generation < self.result_generation {
            return None;
        }
        self.matches.clear();
        self.match_index = None;
        self.result_generation = generation;
        self.result_valid = false;
        self.result_active = true;
        self.result_invalidated = true;
        Some(FindCompletion {
            generation,
            kind: crate::KERO_FIND_RESULT_INVALIDATED,
            total: 0,
            selected: -1,
        })
    }
}

/// Incremental state for a worker-owned Find begin. The worker advances one
/// terminal-lock chunk per event-loop turn so a frame-held lock cannot park
/// PTY parsing indefinitely. Messages that must remain ordered are retained
/// here until the search completes or is cancelled; input bytes are written
/// through while the search is in progress.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct FindEpoch {
    revision: u64,
    topmost_line: Line,
    bottommost_line: Line,
    last_column: Column,
    history_size: usize,
    alternate_screen: bool,
}

struct PendingFindBegin {
    generation: u64,
    regex: Option<RegexSearch>,
    matches: Vec<(Point, Point)>,
    next_start: Option<Point>,
    search_end: Option<Point>,
    epoch: Option<FindEpoch>,
    retry_delay: Duration,
    deferred: VecDeque<GraphicsMsg>,
}

impl PendingFindBegin {
    fn note_lock_busy(&mut self) {
        self.retry_delay = self.retry_delay.min(FIND_RETRY_MAX / 2) * 2;
    }

    fn note_chunk_progress(&mut self) {
        self.retry_delay = FIND_RETRY_MIN;
    }
}

enum FindBeginProgress {
    Complete(FindCompletion),
    Pending,
    WaitingForLock,
    Cancelled,
    Invalidated(FindCompletion),
    Stopped,
}

enum FindFlushResult {
    Continue,
    Cancelled,
    Invalidated,
    Stopped,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct FindCompletion {
    pub(crate) generation: u64,
    pub(crate) kind: u32,
    pub(crate) total: usize,
    pub(crate) selected: isize,
}

struct FindResultInner {
    version: std::sync::atomic::AtomicU64,
    generation: std::sync::atomic::AtomicU64,
    kind: std::sync::atomic::AtomicU32,
    total: std::sync::atomic::AtomicUsize,
    selected: std::sync::atomic::AtomicIsize,
}

/// A single-writer, lock-free result slot for the main-thread poller.
/// Publishing generation last makes a result visible only after all payload
/// fields are written. The slot keeps the newest generation only.
#[derive(Clone)]
pub(crate) struct FindResultStore(Arc<FindResultInner>);

impl FindResultStore {
    pub(crate) fn new() -> Self {
        Self(Arc::new(FindResultInner {
            version: std::sync::atomic::AtomicU64::new(0),
            generation: std::sync::atomic::AtomicU64::new(0),
            kind: std::sync::atomic::AtomicU32::new(0),
            total: std::sync::atomic::AtomicUsize::new(0),
            selected: std::sync::atomic::AtomicIsize::new(-1),
        }))
    }

    pub(crate) fn publish(&self, generation: u64, kind: u32, total: usize, selected: isize) {
        self.publish_inner(generation, kind, total, selected, false);
    }

    pub(crate) fn publish_invalidated(&self, generation: u64) {
        // A direct mutation can enqueue an explicit barrier while a worker
        // completion is already in flight. Both paths may report the same
        // invalidation, but the result slot should expose it only once.
        if self.read().is_some_and(|result| {
            result.generation == generation && result.kind == crate::KERO_FIND_RESULT_INVALIDATED
        }) {
            return;
        }
        self.publish_inner(generation, crate::KERO_FIND_RESULT_INVALIDATED, 0, -1, true);
    }

    fn publish_inner(
        &self,
        generation: u64,
        kind: u32,
        total: usize,
        selected: isize,
        allow_same_generation: bool,
    ) {
        if generation == 0 {
            return;
        }
        let current = self.0.generation.load(std::sync::atomic::Ordering::Acquire);
        if generation < current || (!allow_same_generation && generation == current) {
            return;
        }
        // One writer owns this slot. An odd version marks the payload as
        // changing, and the even version publishes a complete result.
        self.0
            .version
            .fetch_add(1, std::sync::atomic::Ordering::AcqRel);
        self.0
            .kind
            .store(kind, std::sync::atomic::Ordering::Relaxed);
        self.0
            .total
            .store(total, std::sync::atomic::Ordering::Relaxed);
        self.0
            .selected
            .store(selected, std::sync::atomic::Ordering::Relaxed);
        self.0
            .generation
            .store(generation, std::sync::atomic::Ordering::Release);
        self.0
            .version
            .fetch_add(1, std::sync::atomic::Ordering::Release);
    }

    pub(crate) fn read(&self) -> Option<FindCompletion> {
        let version = self.0.version.load(std::sync::atomic::Ordering::Acquire);
        if version == 0 || version % 2 != 0 {
            return None;
        }
        let generation = self.0.generation.load(std::sync::atomic::Ordering::Relaxed);
        if generation == 0 {
            return None;
        }
        let result = FindCompletion {
            generation,
            kind: self.0.kind.load(std::sync::atomic::Ordering::Relaxed),
            total: self.0.total.load(std::sync::atomic::Ordering::Relaxed),
            selected: self.0.selected.load(std::sync::atomic::Ordering::Relaxed),
        };
        let end_version = self.0.version.load(std::sync::atomic::Ordering::Acquire);
        (version == end_version).then_some(result)
    }
}

pub(crate) struct GraphicsEventLoop<T: tty::EventedPty, U: EventListener> {
    poller: Arc<Poller>,
    pty: T,
    receiver: PeekableReceiver<GraphicsMsg>,
    sender: Sender<GraphicsMsg>,
    terminal: Arc<FairMutex<Term<U>>>,
    event_proxy: U,
    graphics: Arc<FairMutex<KittyGraphicsStore>>,
    graphics_size: Arc<FairMutex<KittyGraphicsSize>>,
    mode_snapshot: crate::ModeSnapshot,
    find_state: Arc<FairMutex<FindState>>,
    find_results: FindResultStore,
    frame_handoff: FrameHandoff,
}

fn stop_sync_and_publish_mode<L: EventListener>(
    parser: &mut ansi::Processor,
    terminal: &mut Term<L>,
    mode_snapshot: &crate::ModeSnapshot,
) {
    parser.stop_sync(terminal);
    mode_snapshot.store_term_mode(*terminal.mode());
}

// Reserve the FairMutex turn before taking its data lock. The frame turn is
// held separately, so a non-blocking frame attempt cannot bypass a worker that
// is already waiting for this critical section.
fn lock_terminal_with_reserved_worker_turn<T>(
    terminal: &FairMutex<T>,
) -> impl std::ops::DerefMut<Target = T> + '_ {
    let lease = terminal.lease();
    let terminal = terminal.lock_unfair();
    drop(lease);
    terminal
}

fn lock_terminal_after_frame_handoff<'a, T>(
    handoff: &FrameHandoff,
    terminal: &'a FairMutex<T>,
) -> impl std::ops::DerefMut<Target = T> + 'a {
    // Reserve the next terminal-lock turn before waiting on FairMutex. A
    // pending frame can report BUSY, but it never parks the parser before this
    // point; once a worker is waiting, the frame turn cannot be reclaimed.
    let turn = handoff.reserve_worker_lock();
    let terminal = lock_terminal_with_reserved_worker_turn(terminal);
    drop(turn);
    terminal
}

fn apply_user_input_adjustment<L: EventListener>(terminal: &mut Term<L>) -> bool {
    let selection_changed = terminal.selection.take().is_some();
    let viewport_changed = terminal.grid().display_offset() != 0;
    if viewport_changed {
        terminal.scroll_display(Scroll::Bottom);
    }
    selection_changed || viewport_changed
}

fn apply_pending_user_input_adjustment<L: EventListener>(
    terminal: &mut Term<L>,
    state: &mut GraphicsEventLoopState,
) -> bool {
    if !state.pending_user_input_adjustment {
        return false;
    }
    state.pending_user_input_adjustment = false;
    apply_user_input_adjustment(terminal)
}

fn bump_terminal_revision(state: &mut GraphicsEventLoopState) {
    state.terminal_revision = state.terminal_revision.wrapping_add(1);
}

fn clear_selection<L: EventListener>(terminal: &mut Term<L>) -> bool {
    terminal.selection.take().is_some()
}

fn find_chunk_end<L: EventListener>(terminal: &Term<L>, start: Point, end: Point) -> Point {
    let target_line = Line(
        start
            .line
            .0
            .saturating_add(FIND_CHUNK_LINES - 1)
            .min(end.line.0),
    );
    // End at a real line break so a literal match cannot cross the chunk
    // boundary. A single unusually long wrapped line can exceed the nominal
    // chunk, but ordinary scrollback releases the terminal lock every 64 rows.
    let logical_end = terminal.line_search_right(Point::new(target_line, terminal.last_column()));
    if logical_end.line >= end.line {
        end
    } else {
        logical_end
    }
}

fn find_epoch<L: EventListener>(terminal: &Term<L>, revision: u64) -> FindEpoch {
    FindEpoch {
        revision,
        topmost_line: terminal.topmost_line(),
        bottommost_line: terminal.bottommost_line(),
        last_column: terminal.last_column(),
        history_size: terminal.grid().history_size(),
        alternate_screen: terminal.mode().contains(TermMode::ALT_SCREEN),
    }
}

fn queue_control_input(write_list: &mut VecDeque<Cow<'static, [u8]>>, input: Cow<'static, [u8]>) {
    write_list.push_back(input);
}

enum MessageEffect {
    Continue { wakeup: bool },
    Find(FindMessage),
    InvalidateFind(Option<u64>),
    Resize(WindowSize),
    Shutdown,
}

pub(crate) fn apply_find_message<L: EventListener>(
    terminal: &mut Term<L>,
    state: &mut FindState,
    message: FindMessage,
) -> FindCompletion {
    match message {
        FindMessage::Begin { generation, needle } => {
            state.begin(generation);
            terminal.selection = None;

            if needle.is_empty() {
                if !state.complete(generation) {
                    return FindCompletion {
                        generation,
                        kind: crate::KERO_FIND_RESULT_INVALIDATED,
                        total: 0,
                        selected: -1,
                    };
                }
                return FindCompletion {
                    generation,
                    kind: crate::KERO_FIND_RESULT_BEGIN,
                    total: 0,
                    selected: -1,
                };
            }

            let Ok(mut regex) =
                alacritty_terminal::term::search::RegexSearch::new(&crate::regex_escape(&needle))
            else {
                if !state.complete(generation) {
                    return FindCompletion {
                        generation,
                        kind: crate::KERO_FIND_RESULT_INVALIDATED,
                        total: 0,
                        selected: -1,
                    };
                }
                return FindCompletion {
                    generation,
                    kind: crate::KERO_FIND_RESULT_BEGIN,
                    total: 0,
                    selected: -1,
                };
            };

            let start = Point::new(terminal.topmost_line(), Column(0));
            let end = Point::new(terminal.bottommost_line(), terminal.last_column());
            for found in RegexIter::new(start, end, Direction::Right, &*terminal, &mut regex) {
                state.matches.push((*found.start(), *found.end()));
                // Keep the existing public count bound. The work still runs
                // on the PTY owner, so the UI thread never scans this range.
                if state.matches.len() >= FIND_MATCH_LIMIT {
                    break;
                }
            }

            if !state.complete(generation) {
                state.matches.clear();
                return FindCompletion {
                    generation,
                    kind: crate::KERO_FIND_RESULT_INVALIDATED,
                    total: 0,
                    selected: -1,
                };
            }
            FindCompletion {
                generation,
                kind: crate::KERO_FIND_RESULT_BEGIN,
                total: state.matches.len(),
                selected: -1,
            }
        }
        FindMessage::Step {
            generation,
            forward,
        } => {
            if generation != 0 && generation < state.result_generation {
                return FindCompletion {
                    generation,
                    kind: crate::KERO_FIND_RESULT_STEP,
                    total: 0,
                    selected: -1,
                };
            }
            if generation != 0
                && (!state.result_active || !state.result_valid || state.result_invalidated)
            {
                // An invalidated result cannot be navigated. Report the
                // invalidation under the active request generation so the
                // host can trigger a fresh Begin even if it has not consumed
                // the previous invalidation yet.
                state.result_generation = generation;
                state.result_active = true;
                state.result_valid = false;
                state.result_invalidated = true;
                return FindCompletion {
                    generation,
                    kind: crate::KERO_FIND_RESULT_INVALIDATED,
                    total: 0,
                    selected: -1,
                };
            }
            if generation != 0 {
                state.result_generation = generation;
            }
            let count = state.matches.len();
            if count == 0 {
                return FindCompletion {
                    generation,
                    kind: crate::KERO_FIND_RESULT_STEP,
                    total: 0,
                    selected: -1,
                };
            }

            let index = match state.match_index {
                Some(index) if forward => (index + 1) % count,
                Some(index) => (index + count - 1) % count,
                None if forward => 0,
                None => count - 1,
            };
            state.match_index = Some(index);
            let (start, end) = state.matches[index];

            let mut selection = Selection::new(SelectionType::Simple, start, Side::Left);
            selection.update(end, Side::Right);
            terminal.selection = Some(selection);
            terminal.scroll_to_point(start);

            FindCompletion {
                generation,
                kind: crate::KERO_FIND_RESULT_STEP,
                total: count,
                selected: index as isize,
            }
        }
        FindMessage::End { generation } => {
            if generation != 0 && generation < state.result_generation {
                return FindCompletion {
                    generation,
                    kind: crate::KERO_FIND_RESULT_END,
                    total: 0,
                    selected: -1,
                };
            }
            state.matches.clear();
            state.match_index = None;
            state.result_generation = generation;
            state.result_valid = false;
            state.result_active = false;
            state.result_invalidated = false;
            terminal.selection = None;
            FindCompletion {
                generation,
                kind: crate::KERO_FIND_RESULT_END,
                total: 0,
                selected: -1,
            }
        }
    }
}

fn apply_message<L: EventListener>(
    terminal: Option<&mut Term<L>>,
    state: &mut GraphicsEventLoopState,
    message: GraphicsMsg,
) -> MessageEffect {
    match message {
        GraphicsMsg::Input(input) => {
            queue_control_input(&mut state.write_list, input);
            MessageEffect::Continue { wakeup: false }
        }
        GraphicsMsg::UserInput(input) => {
            // The PTY write path must not wait for a display frame. Apply the
            // terminal-side viewport/selection adjustment when a caller has
            // already supplied the lock; the event-loop path can defer that
            // adjustment while still making the bytes writable immediately.
            state.write_list.push_back(input);
            let wakeup = if let Some(terminal) = terminal {
                state.pending_user_input_adjustment = false;
                apply_user_input_adjustment(terminal)
            } else {
                state.pending_user_input_adjustment = true;
                false
            };
            MessageEffect::Continue { wakeup }
        }
        GraphicsMsg::ClearSelection => {
            let terminal = terminal.expect("clear selection requires the terminal lock");
            MessageEffect::Continue {
                wakeup: clear_selection(terminal),
            }
        }
        GraphicsMsg::InvalidateFind => MessageEffect::InvalidateFind(None),
        GraphicsMsg::InvalidateFindWithGeneration(generation) => {
            MessageEffect::InvalidateFind(Some(generation))
        }
        GraphicsMsg::Find(message) => MessageEffect::Find(message),
        GraphicsMsg::Resize(size) => {
            state.graphics_cursor_tracker.reset_scroll_region();
            MessageEffect::Resize(size)
        }
        GraphicsMsg::Shutdown => MessageEffect::Shutdown,
    }
}

impl<T, U> GraphicsEventLoop<T, U>
where
    T: tty::EventedPty + OnResize + Send + 'static,
    U: EventListener + Send + 'static,
{
    pub(crate) fn new(
        terminal: Arc<FairMutex<Term<U>>>,
        event_proxy: U,
        pty: T,
        graphics: Arc<FairMutex<KittyGraphicsStore>>,
        graphics_size: Arc<FairMutex<KittyGraphicsSize>>,
        mode_snapshot: crate::ModeSnapshot,
        find_state: Arc<FairMutex<FindState>>,
        find_results: FindResultStore,
        frame_handoff: FrameHandoff,
    ) -> io::Result<Self> {
        let (sender, receiver) = mpsc::channel();
        let poller = Arc::new(Poller::new()?);
        Ok(Self {
            poller,
            pty,
            receiver: PeekableReceiver::new(receiver),
            sender,
            terminal,
            event_proxy,
            graphics,
            graphics_size,
            mode_snapshot,
            find_state,
            find_results,
            frame_handoff,
        })
    }

    pub(crate) fn channel(&self) -> GraphicsEventLoopSender {
        GraphicsEventLoopSender {
            sender: self.sender.clone(),
            poller: self.poller.clone(),
        }
    }

    /// Pull PTY-bound bytes past queued Find work without waiting for a
    /// terminal lock. Control messages stay in `deferred` so a barrier is not
    /// rediscovered on every search chunk. Input after a barrier is safe to
    /// write now: the barrier itself remains ahead of the next terminal/parser
    /// action when the deferred queue is restored.
    fn flush_queued_io_while_finding(
        &mut self,
        state: &mut GraphicsEventLoopState,
        deferred: &mut VecDeque<GraphicsMsg>,
    ) -> FindFlushResult {
        let mut wakeup = false;
        let mut cancelled = false;
        let mut invalidated = false;
        while let Some(message) = self.receiver.recv() {
            match message {
                GraphicsMsg::Input(input) => {
                    queue_control_input(&mut state.write_list, input);
                }
                GraphicsMsg::UserInput(input) => {
                    let MessageEffect::Continue {
                        wakeup: input_wakeup,
                    } = apply_message::<U>(None, state, GraphicsMsg::UserInput(input))
                    else {
                        unreachable!("user input must continue");
                    };
                    wakeup |= input_wakeup;
                }
                GraphicsMsg::Find(message) => {
                    cancelled |=
                        matches!(message, FindMessage::Begin { .. } | FindMessage::End { .. });
                    deferred.push_back(GraphicsMsg::Find(message));
                }
                GraphicsMsg::ClearSelection => {
                    deferred.push_back(GraphicsMsg::ClearSelection);
                }
                message @ (GraphicsMsg::InvalidateFind
                | GraphicsMsg::InvalidateFindWithGeneration(_)) => {
                    deferred.push_back(message);
                    // Content reset is a coordinate-space barrier just like a
                    // resize. Cancel the search before any following input is
                    // parsed against the cleared grid.
                    cancelled = true;
                    invalidated = true;
                    break;
                }
                GraphicsMsg::Resize(size) => {
                    deferred.push_back(GraphicsMsg::Resize(size));
                    // A resize changes the terminal coordinate space. End
                    // this incremental search at the message boundary so
                    // the resize is applied before any following input or
                    // Find command, instead of being postponed until a
                    // potentially long search completes.
                    cancelled = true;
                    invalidated = true;
                    break;
                }
                GraphicsMsg::Shutdown => {
                    deferred.push_back(GraphicsMsg::Shutdown);
                    cancelled = true;
                    break;
                }
            }
        }

        wakeup |= self.try_apply_pending_user_input_adjustment(state);
        if let Err(error) = self.pty_write(state) {
            eprintln!("kero: Alacritty PTY write failed during find: {error}");
            return FindFlushResult::Stopped;
        }
        // Do not call `finish_user_input_after_write` here. It takes the
        // terminal lock after the bytes are written and can still park the
        // worker behind a frame, preventing the next input or parser turn.
        // The pending adjustment is retried by the next safe worker point.
        if wakeup {
            self.event_proxy.send_event(Event::Wakeup);
        }
        if invalidated {
            FindFlushResult::Invalidated
        } else if cancelled {
            FindFlushResult::Cancelled
        } else {
            FindFlushResult::Continue
        }
    }

    fn start_find_begin(
        &mut self,
        state: &mut GraphicsEventLoopState,
        generation: u64,
        needle: String,
    ) {
        {
            let mut find_state = self.find_state.lock();
            find_state.begin(generation);
        }

        let regex = if needle.is_empty() {
            None
        } else {
            RegexSearch::new(&crate::regex_escape(&needle)).ok()
        };
        state.pending_find = Some(PendingFindBegin {
            generation,
            regex,
            matches: Vec::new(),
            next_start: None,
            search_end: None,
            epoch: None,
            retry_delay: FIND_RETRY_MIN,
            deferred: VecDeque::new(),
        });
    }

    /// Search scrollback in one bounded terminal-lock chunk. A busy frame
    /// returns `Pending` to the event loop, which can parse PTY readiness and
    /// accept new input before retrying. This is the cancellation/fairness
    /// boundary that replaces the old unbounded 50us lock loop.
    fn advance_find_begin(&mut self, state: &mut GraphicsEventLoopState) -> FindBeginProgress {
        let Some(mut find) = state.pending_find.take() else {
            return FindBeginProgress::Cancelled;
        };

        let progress = match self.flush_queued_io_while_finding(state, &mut find.deferred) {
            FindFlushResult::Continue => self.advance_find_chunk(state, &mut find),
            FindFlushResult::Cancelled => FindBeginProgress::Cancelled,
            FindFlushResult::Invalidated => FindBeginProgress::Invalidated(FindCompletion {
                generation: find.generation,
                kind: crate::KERO_FIND_RESULT_INVALIDATED,
                total: 0,
                selected: -1,
            }),
            FindFlushResult::Stopped => FindBeginProgress::Stopped,
        };

        match progress {
            FindBeginProgress::Pending => {
                state.pending_find = Some(find);
            }
            FindBeginProgress::WaitingForLock => {
                find.note_lock_busy();
                state.pending_find = Some(find);
            }
            FindBeginProgress::Complete(_)
            | FindBeginProgress::Cancelled
            | FindBeginProgress::Invalidated(_)
            | FindBeginProgress::Stopped => self.receiver.prepend(find.deferred),
        }
        progress
    }

    fn advance_find_chunk(
        &mut self,
        state: &mut GraphicsEventLoopState,
        find: &mut PendingFindBegin,
    ) -> FindBeginProgress {
        if find
            .epoch
            .is_some_and(|epoch| epoch.revision != state.terminal_revision)
        {
            return FindBeginProgress::Invalidated(FindCompletion {
                generation: find.generation,
                kind: crate::KERO_FIND_RESULT_INVALIDATED,
                total: 0,
                selected: -1,
            });
        }

        let Some(turn) = self.frame_handoff.try_reserve_worker_lock() else {
            return FindBeginProgress::WaitingForLock;
        };
        let Some(mut terminal) = self.terminal.try_lock_unfair() else {
            drop(turn);
            return FindBeginProgress::WaitingForLock;
        };

        find.note_chunk_progress();

        let epoch = find_epoch(&terminal, state.terminal_revision);
        if find.epoch.is_some_and(|previous| previous != epoch) {
            drop(terminal);
            drop(turn);
            return FindBeginProgress::Invalidated(FindCompletion {
                generation: find.generation,
                kind: crate::KERO_FIND_RESULT_INVALIDATED,
                total: 0,
                selected: -1,
            });
        }
        let chunk_start = match find.next_start {
            Some(start) => start,
            None => {
                terminal.selection = None;
                find.epoch = Some(epoch);
                let search_end = Point::new(epoch.bottommost_line, epoch.last_column);
                find.search_end = Some(search_end);
                Point::new(epoch.topmost_line, Column(0))
            }
        };

        let Some(regex) = find.regex.as_mut() else {
            drop(terminal);
            drop(turn);
            return if self.find_state.lock().complete(find.generation) {
                FindBeginProgress::Complete(FindCompletion {
                    generation: find.generation,
                    kind: crate::KERO_FIND_RESULT_BEGIN,
                    total: 0,
                    selected: -1,
                })
            } else {
                FindBeginProgress::Invalidated(FindCompletion {
                    generation: find.generation,
                    kind: crate::KERO_FIND_RESULT_INVALIDATED,
                    total: 0,
                    selected: -1,
                })
            };
        };

        let search_end = find.search_end.expect("find search end initialized");
        let chunk_end = find_chunk_end(&terminal, chunk_start, search_end);
        for found in RegexIter::new(chunk_start, chunk_end, Direction::Right, &*terminal, regex) {
            find.matches.push((*found.start(), *found.end()));
            if find.matches.len() >= FIND_MATCH_LIMIT {
                break;
            }
        }
        let complete = chunk_end == search_end || find.matches.len() >= FIND_MATCH_LIMIT;
        let following = chunk_end.add(&*terminal, Boundary::None, 1);
        drop(terminal);
        drop(turn);

        if complete {
            let total = find.matches.len();
            let mut find_state = self.find_state.lock();
            if find_state.complete(find.generation) {
                find_state.matches = std::mem::take(&mut find.matches);
                find_state.match_index = None;
                FindBeginProgress::Complete(FindCompletion {
                    generation: find.generation,
                    kind: crate::KERO_FIND_RESULT_BEGIN,
                    total,
                    selected: -1,
                })
            } else {
                find.matches.clear();
                FindBeginProgress::Invalidated(FindCompletion {
                    generation: find.generation,
                    kind: crate::KERO_FIND_RESULT_INVALIDATED,
                    total: 0,
                    selected: -1,
                })
            }
        } else {
            find.next_start = Some(following);
            FindBeginProgress::Pending
        }
    }

    fn invalidate_find_matches(&self) -> Option<u64> {
        self.find_state.lock().invalidate()
    }

    fn publish_find_result(&self, result: FindCompletion) {
        if result.kind == crate::KERO_FIND_RESULT_INVALIDATED {
            self.find_results.publish_invalidated(result.generation);
            return;
        }

        // A direct UI resize/clear can invalidate the state after an
        // incremental Begin releases the terminal lock but before this
        // worker publishes its completion. Do not publish that old payload;
        // preserve the invalidation protocol for the same active generation.
        // Keep the state lock through the result-slot write so a direct grid
        // mutation cannot pass this check and invalidate between it and the
        // publication.
        if result.kind == crate::KERO_FIND_RESULT_BEGIN && result.generation != 0 {
            let find_state = self.find_state.lock();
            if find_state.result_generation != result.generation {
                return;
            }
            if find_state.result_active && find_state.result_valid && !find_state.result_invalidated
            {
                self.find_results.publish(
                    result.generation,
                    result.kind,
                    result.total,
                    result.selected,
                );
            } else {
                self.find_results.publish_invalidated(result.generation);
            }
            return;
        }

        self.find_results.publish(
            result.generation,
            result.kind,
            result.total,
            result.selected,
        );
    }

    fn drain_messages(&mut self, state: &mut GraphicsEventLoopState) -> bool {
        if state.pending_find.is_some() {
            match self.advance_find_begin(state) {
                FindBeginProgress::Complete(result) => {
                    self.publish_find_result(result);
                    self.event_proxy.send_event(Event::Wakeup);
                }
                FindBeginProgress::Pending => return true,
                FindBeginProgress::WaitingForLock => return true,
                FindBeginProgress::Cancelled => {}
                FindBeginProgress::Invalidated(result) => {
                    self.publish_find_result(result);
                    self.event_proxy.send_event(Event::Wakeup);
                }
                FindBeginProgress::Stopped => return false,
            }
        }

        while let Some(message) = self.receiver.recv() {
            let effect = match message {
                GraphicsMsg::Input(input) => {
                    apply_message::<U>(None, state, GraphicsMsg::Input(input))
                }
                GraphicsMsg::UserInput(input) => {
                    let MessageEffect::Continue { wakeup } =
                        apply_message::<U>(None, state, GraphicsMsg::UserInput(input))
                    else {
                        unreachable!("user input must continue");
                    };
                    let wakeup = self.try_apply_pending_user_input_adjustment(state) || wakeup;
                    MessageEffect::Continue { wakeup }
                }
                GraphicsMsg::ClearSelection => {
                    let mut terminal =
                        lock_terminal_after_frame_handoff(&self.frame_handoff, &self.terminal);
                    apply_message(Some(&mut terminal), state, GraphicsMsg::ClearSelection)
                }
                GraphicsMsg::InvalidateFind => {
                    apply_message::<U>(None, state, GraphicsMsg::InvalidateFind)
                }
                GraphicsMsg::InvalidateFindWithGeneration(generation) => apply_message::<U>(
                    None,
                    state,
                    GraphicsMsg::InvalidateFindWithGeneration(generation),
                ),
                GraphicsMsg::Find(message) => {
                    apply_message::<U>(None, state, GraphicsMsg::Find(message))
                }
                GraphicsMsg::Resize(size) => {
                    apply_message::<U>(None, state, GraphicsMsg::Resize(size))
                }
                GraphicsMsg::Shutdown => apply_message::<U>(None, state, GraphicsMsg::Shutdown),
            };
            match effect {
                MessageEffect::Continue { wakeup } => {
                    if wakeup {
                        self.event_proxy.send_event(Event::Wakeup);
                    }
                }
                MessageEffect::Find(message) => {
                    let result = match message {
                        FindMessage::Begin { generation, needle } => {
                            self.start_find_begin(state, generation, needle);
                            match self.advance_find_begin(state) {
                                FindBeginProgress::Complete(result) => {
                                    self.publish_find_result(result);
                                    self.event_proxy.send_event(Event::Wakeup);
                                }
                                FindBeginProgress::Pending => return true,
                                FindBeginProgress::WaitingForLock => return true,
                                FindBeginProgress::Cancelled => continue,
                                FindBeginProgress::Invalidated(result) => {
                                    self.publish_find_result(result);
                                    self.event_proxy.send_event(Event::Wakeup);
                                    continue;
                                }
                                FindBeginProgress::Stopped => return false,
                            }
                            continue;
                        }
                        message => {
                            let step_generation = match &message {
                                FindMessage::Step { generation, .. } => Some(*generation),
                                FindMessage::Begin { .. } | FindMessage::End { .. } => None,
                            };
                            let mut deferred = VecDeque::new();
                            match self.flush_queued_io_while_finding(state, &mut deferred) {
                                FindFlushResult::Continue => {}
                                FindFlushResult::Cancelled => {
                                    self.receiver.prepend(deferred);
                                    continue;
                                }
                                FindFlushResult::Invalidated => {
                                    if let Some(generation) = step_generation {
                                        if let Some(result) = self
                                            .find_state
                                            .lock()
                                            .step_after_invalidation(generation)
                                        {
                                            self.publish_find_result(result);
                                            self.event_proxy.send_event(Event::Wakeup);
                                        }
                                    }
                                    self.receiver.prepend(deferred);
                                    continue;
                                }
                                FindFlushResult::Stopped => return false,
                            }
                            let mut terminal = lock_terminal_after_frame_handoff(
                                &self.frame_handoff,
                                &self.terminal,
                            );
                            let mut find_state = self.find_state.lock();
                            let result =
                                apply_find_message(&mut terminal, &mut find_state, message);
                            drop(find_state);
                            drop(terminal);
                            self.receiver.prepend(deferred);
                            result
                        }
                    };
                    self.publish_find_result(result);
                    self.event_proxy.send_event(Event::Wakeup);
                }
                MessageEffect::InvalidateFind(preinvalidated_generation) => {
                    bump_terminal_revision(state);
                    let generation = preinvalidated_generation.or(self.invalidate_find_matches());
                    if let Some(generation) = generation {
                        self.find_results.publish_invalidated(generation);
                    }
                    self.event_proxy.send_event(Event::Wakeup);
                }
                MessageEffect::Resize(size) => {
                    bump_terminal_revision(state);
                    if let Some(generation) = self.invalidate_find_matches() {
                        self.find_results.publish_invalidated(generation);
                        self.event_proxy.send_event(Event::Wakeup);
                    }
                    self.pty.on_resize(size);
                }
                MessageEffect::Shutdown => return false,
            }
        }
        true
    }

    /// Selection clearing and viewport snapping are best-effort at message
    /// drain time. A busy frame must not delay the PTY write queue; the
    /// adjustment is retried before the next parser lock acquisition or after
    /// the queued bytes have finished writing.
    fn try_apply_pending_user_input_adjustment(&self, state: &mut GraphicsEventLoopState) -> bool {
        if !state.pending_user_input_adjustment {
            return false;
        }
        let Some(turn) = self.frame_handoff.try_reserve_worker_lock() else {
            return false;
        };
        let Some(mut terminal) = self.terminal.try_lock_unfair() else {
            drop(turn);
            return false;
        };
        let wakeup = apply_pending_user_input_adjustment(&mut terminal, state);
        if wakeup {
            bump_terminal_revision(state);
        }
        drop(terminal);
        drop(turn);
        wakeup
    }

    /// Once the input bytes are fully written, finish the terminal-side
    /// adjustment in this worker cycle. This may wait for an active frame, but
    /// the user input has already reached the PTY and is never held behind the
    /// frame handoff.
    fn finish_user_input_after_write(&self, state: &mut GraphicsEventLoopState) -> bool {
        if !state.pending_user_input_adjustment || state.needs_write() {
            return false;
        }
        let mut terminal = lock_terminal_after_frame_handoff(&self.frame_handoff, &self.terminal);
        let wakeup = apply_pending_user_input_adjustment(&mut terminal, state);
        drop(terminal);
        wakeup
    }

    fn apply_text_item(
        &self,
        state: &mut GraphicsEventLoopState,
        terminal: &mut Term<U>,
        text: &[u8],
    ) -> bool {
        let track_scrolls = self.graphics.lock().state.has_placements();
        let effects = advance_text_with_mode_snapshot(
            &mut state.graphics_cursor_tracker,
            &mut state.parser,
            terminal,
            text,
            &self.mode_snapshot,
            track_scrolls,
        );
        let mut graphics = self.graphics.lock();
        if effects.apply_to(&mut graphics.state) {
            graphics.mark_changed();
            true
        } else {
            false
        }
    }

    fn capture_kitty_context(
        &self,
        state: &mut GraphicsEventLoopState,
        terminal: &mut Term<U>,
        command: KittyGraphicsCommand,
    ) -> PendingKittyCommand {
        // Alacritty buffers everything between DECSET/DECRST 2026, including
        // cursor movement. Kitty commands are intercepted outside that parser,
        // so commit the buffered terminal operations before reading the cursor
        // used to anchor an image placement. Kero still suppresses presentation
        // until the outer synchronized update ends, preserving atomicity.
        if state.parser.sync_bytes_count() > 0 {
            stop_sync_and_publish_mode(&mut state.parser, terminal, &self.mode_snapshot);
        }
        let cursor = terminal.grid().cursor.point;
        let screen = KittyGraphicsScreen::from_alternate_screen(
            terminal.mode().contains(TermMode::ALT_SCREEN),
        );
        let full_screen_scroll_region = state
            .graphics_cursor_tracker
            .region_covers_full_screen(terminal.grid().screen_lines());
        let mut size = *self.graphics_size.lock();
        size.columns = terminal.grid().columns();
        size.rows = terminal.grid().screen_lines();
        PendingKittyCommand {
            command,
            cursor_column: cursor.column.0,
            cursor_row: cursor.line.0.max(0) as usize,
            history_size: terminal.grid().history_size(),
            size,
            screen,
            full_screen_scroll_region,
        }
    }

    /// Decode and place Kitty images without the terminal mutex. PNG inflate
    /// can take tens of milliseconds; holding `term` that long stalls the
    /// host snapshot on the main thread.
    fn apply_pending_kitty(
        &self,
        state: &mut GraphicsEventLoopState,
        pending: PendingKittyCommand,
    ) -> bool {
        let mut graphics_changed = false;
        {
            let command = pending;
            let screen = command.screen;
            let full_screen_scroll_region = command.full_screen_scroll_region;
            let context = PlacementContext {
                cursor_column: command.cursor_column,
                cursor_row: command.cursor_row,
                history_size: command.history_size,
                size: command.size,
                screen: command.screen,
            };
            let decoded = command
                .command
                .needs_payload_decode()
                .then(|| decode_payload(&command.command));
            let stage = {
                let mut graphics = self.graphics.lock();
                graphics.state.stage(command.command, decoded, context)
            };
            // Prepare one command at a time. This bounds the number of large
            // decoded/normalized images retained before quota enforcement.
            let ready = match stage {
                KittyGraphicsStage::Noop => KittyGraphicsReady::Noop,
                KittyGraphicsStage::Direct { command, context } => {
                    KittyGraphicsReady::Direct { command, context }
                }
                KittyGraphicsStage::Failure(result) => KittyGraphicsReady::Failure(result),
                KittyGraphicsStage::Upload(upload) => {
                    let command_for_error = upload.command.response_metadata();
                    match prepare_upload(upload) {
                        Ok(prepared) => KittyGraphicsReady::Image(prepared),
                        Err(error) => {
                            let graphics = self.graphics.lock();
                            KittyGraphicsReady::Failure(
                                graphics.state.failure(&command_for_error, &error),
                            )
                        }
                    }
                }
            };

            let needs_commit = matches!(
                &ready,
                KittyGraphicsReady::Direct { .. } | KittyGraphicsReady::Image(_)
            );
            let mut worker_turn = needs_commit.then(|| self.frame_handoff.reserve_worker_lock());
            let result = match ready {
                KittyGraphicsReady::Noop => {
                    crate::kitty_graphics::KittyGraphicsApplyResult::default()
                }
                KittyGraphicsReady::Failure(result) => result,
                KittyGraphicsReady::Direct { command, context } => {
                    let mut graphics = self.graphics.lock();
                    let result = graphics.state.commit_direct(command, context);
                    if result.changed {
                        graphics.mark_changed();
                    }
                    result
                }
                KittyGraphicsReady::Image(prepared) => {
                    let mut graphics = self.graphics.lock();
                    let result = graphics.state.commit_prepared(prepared);
                    if result.changed {
                        graphics.mark_changed();
                    }
                    result
                }
            };
            if let Some(response) = result.response {
                state.write_list.push_back(Cow::Owned(response));
            }
            graphics_changed |= result.changed;
            if result.cursor_advance_screen == Some(screen) {
                if let Some(advance) = result.cursor_advance {
                    let mut terminal = lock_terminal_with_reserved_worker_turn(&self.terminal);
                    let untracked_scroll = advance_cursor(
                        &mut terminal,
                        advance.0,
                        advance.1,
                        full_screen_scroll_region,
                    );
                    if untracked_scroll > 0 {
                        let mut graphics = self.graphics.lock();
                        if graphics
                            .state
                            .scroll_up_without_history(untracked_scroll, screen)
                        {
                            graphics.mark_changed();
                            graphics_changed = true;
                        }
                    }
                    drop(terminal);
                }
            }
            drop(worker_turn.take());
        }
        graphics_changed
    }

    fn pty_read(
        &mut self,
        state: &mut GraphicsEventLoopState,
        buffer: &mut [u8],
    ) -> io::Result<()> {
        let mut unprocessed = 0;
        let mut processed = 0;
        let mut graphics_changed = false;
        let mut user_input_changed = false;

        loop {
            if processed >= MAX_LOCKED_READ {
                break;
            }
            let remaining = MAX_LOCKED_READ - processed;
            let read_end = (unprocessed + remaining).min(buffer.len());
            if read_end <= unprocessed {
                break;
            }
            match self.pty.reader().read(&mut buffer[unprocessed..read_end]) {
                Ok(0) if unprocessed == 0 => break,
                Ok(count) => unprocessed += count,
                Err(error) => match error.kind() {
                    ErrorKind::Interrupted => continue,
                    ErrorKind::WouldBlock => {
                        if unprocessed == 0 {
                            break;
                        }
                    }
                    _ => return Err(error),
                },
            }
            if unprocessed == 0 {
                continue;
            }

            // Keep interceptor items in stream order. Text is parsed while a
            // terminal lock is held; a Kitty command captures the current
            // context, releases that lock for decode/commit, then reacquires it
            // before processing the next item.
            let items = state.graphics_interceptor.process(&buffer[..unprocessed]);
            let mut terminal =
                lock_terminal_after_frame_handoff(&self.frame_handoff, &self.terminal);
            // Any parsed bytes may change row contents, cursor state, scrollback
            // storage, or the active screen. Invalidate an incremental Find
            // before its next chunk can reuse coordinates from this epoch.
            bump_terminal_revision(state);
            if let Some(generation) = self.invalidate_find_matches() {
                self.find_results.publish_invalidated(generation);
                self.event_proxy.send_event(Event::Wakeup);
            }
            user_input_changed |= apply_pending_user_input_adjustment(&mut terminal, state);
            for item in items {
                match item {
                    KittyGraphicsItem::Text(text) => {
                        graphics_changed |= self.apply_text_item(state, &mut terminal, &text);
                    }
                    KittyGraphicsItem::Command(command) => {
                        let pending = self.capture_kitty_context(state, &mut terminal, command);
                        self.mode_snapshot.store_term_mode(*terminal.mode());
                        drop(terminal);
                        graphics_changed |= self.apply_pending_kitty(state, pending);
                        terminal =
                            lock_terminal_after_frame_handoff(&self.frame_handoff, &self.terminal);
                    }
                }
            }
            self.mode_snapshot.store_term_mode(*terminal.mode());
            drop(terminal);
            processed += unprocessed;
            unprocessed = 0;
        }

        if user_input_changed
            || graphics_changed
            || (state.parser.sync_bytes_count() < processed && processed > 0)
        {
            self.event_proxy.send_event(Event::Wakeup);
        }
        Ok(())
    }

    fn pty_write(&mut self, state: &mut GraphicsEventLoopState) -> io::Result<()> {
        state.ensure_next();
        'write_many: while let Some(mut current) = state.take_current() {
            'write_one: loop {
                match self.pty.writer().write(current.remaining_bytes()) {
                    Ok(0) => {
                        state.set_current(Some(current));
                        break 'write_many;
                    }
                    Ok(count) => {
                        current.advance(count);
                        if current.finished() {
                            state.goto_next();
                            break 'write_one;
                        }
                    }
                    Err(error) => {
                        state.set_current(Some(current));
                        match error.kind() {
                            ErrorKind::Interrupted | ErrorKind::WouldBlock => break 'write_many,
                            _ => return Err(error),
                        }
                    }
                }
            }
        }
        Ok(())
    }

    pub(crate) fn spawn(mut self) -> JoinHandle<()> {
        std::thread::Builder::new()
            .name("Yeet Alacritty PTY".into())
            .spawn(move || {
                let mut state = GraphicsEventLoopState::default();
                let mut buffer = [0u8; READ_BUFFER_SIZE];
                let poll_mode = PollMode::Level;
                let mut interest = PollingEvent::readable(0);

                if let Err(error) = unsafe { self.pty.register(&self.poller, interest, poll_mode) }
                {
                    eprintln!("kero: Alacritty event loop registration failed: {error}");
                    return;
                }

                let mut events = Events::with_capacity(NonZeroUsize::new(1024).unwrap());
                'event_loop: loop {
                    let parser_timeout = state
                        .parser
                        .sync_timeout()
                        .sync_timeout()
                        .map(|timeout| timeout.saturating_duration_since(Instant::now()));
                    let timeout = if state.pending_find.is_some() {
                        let find_timeout = state
                            .pending_find
                            .as_ref()
                            .map(|find| find.retry_delay)
                            .unwrap_or(FIND_RETRY_MIN);
                        Some(
                            parser_timeout
                                .map(|timeout| timeout.min(find_timeout))
                                .unwrap_or(find_timeout),
                        )
                    } else {
                        parser_timeout
                    };
                    events.clear();
                    if let Err(error) = self.poller.wait(&mut events, timeout) {
                        match error.kind() {
                            ErrorKind::Interrupted => continue,
                            _ => {
                                eprintln!("kero: Alacritty polling failed: {error}");
                                break;
                            }
                        }
                    }

                    if state.pending_find.is_none()
                        && events.is_empty()
                        && self.receiver.peek().is_none()
                    {
                        let mut terminal =
                            lock_terminal_after_frame_handoff(&self.frame_handoff, &self.terminal);
                        apply_pending_user_input_adjustment(&mut terminal, &mut state);
                        stop_sync_and_publish_mode(
                            &mut state.parser,
                            &mut terminal,
                            &self.mode_snapshot,
                        );
                        drop(terminal);
                        self.event_proxy.send_event(Event::Wakeup);
                        continue;
                    }
                    if !self.drain_messages(&mut state) {
                        break;
                    }

                    for event in events.iter() {
                        match event.key {
                            PTY_CHILD_EVENT_TOKEN => {
                                if let Some(tty::ChildEvent::Exited(status)) =
                                    self.pty.next_child_event()
                                {
                                    if let Some(status) = status {
                                        self.event_proxy.send_event(Event::ChildExit(status));
                                    }
                                    lock_terminal_after_frame_handoff(
                                        &self.frame_handoff,
                                        &self.terminal,
                                    )
                                    .exit();
                                    self.event_proxy.send_event(Event::Wakeup);
                                    break 'event_loop;
                                }
                            }
                            PTY_READ_WRITE_TOKEN => {
                                if event.is_interrupt() {
                                    continue;
                                }
                                if event.readable {
                                    if let Err(error) = self.pty_read(&mut state, &mut buffer) {
                                        eprintln!("kero: Alacritty PTY read failed: {error}");
                                        break 'event_loop;
                                    }
                                }
                                if event.writable {
                                    if let Err(error) = self.pty_write(&mut state) {
                                        eprintln!("kero: Alacritty PTY write failed: {error}");
                                        break 'event_loop;
                                    }
                                    if self.finish_user_input_after_write(&mut state) {
                                        bump_terminal_revision(&mut state);
                                        self.event_proxy.send_event(Event::Wakeup);
                                    }
                                }
                            }
                            _ => {}
                        }
                    }

                    let needs_write = state.needs_write();
                    if needs_write != interest.writable {
                        interest.writable = needs_write;
                        if let Err(error) = self.pty.reregister(&self.poller, interest, poll_mode) {
                            eprintln!("kero: Alacritty PTY registration update failed: {error}");
                            break;
                        }
                    }
                }
                let _ = self.pty.deregister(&self.poller);
            })
            .expect("spawn Yeet Alacritty PTY event loop")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alacritty_terminal::event::VoidListener;
    use alacritty_terminal::index::{Column, Line, Point, Side};
    use alacritty_terminal::selection::{Selection, SelectionType};
    use alacritty_terminal::term::{Config, Term};
    use alacritty_terminal::tty::{EventedPty, EventedReadWrite};
    use alacritty_terminal::vte::ansi::Processor;
    use std::io::Cursor;
    use std::time::Duration;

    struct TestPty {
        reader: Cursor<Vec<u8>>,
        writer: Vec<u8>,
    }

    impl EventedReadWrite for TestPty {
        type Reader = Cursor<Vec<u8>>;
        type Writer = Vec<u8>;

        unsafe fn register(
            &mut self,
            _: &Arc<Poller>,
            _: PollingEvent,
            _: PollMode,
        ) -> io::Result<()> {
            Ok(())
        }

        fn reregister(&mut self, _: &Arc<Poller>, _: PollingEvent, _: PollMode) -> io::Result<()> {
            Ok(())
        }

        fn deregister(&mut self, _: &Arc<Poller>) -> io::Result<()> {
            Ok(())
        }

        fn reader(&mut self) -> &mut Self::Reader {
            &mut self.reader
        }

        fn writer(&mut self) -> &mut Self::Writer {
            &mut self.writer
        }
    }

    impl EventedPty for TestPty {
        fn next_child_event(&mut self) -> Option<tty::ChildEvent> {
            None
        }
    }

    impl OnResize for TestPty {
        fn on_resize(&mut self, _: WindowSize) {}
    }

    #[derive(Clone)]
    struct SharedWriter(Arc<std::sync::Mutex<Vec<u8>>>);

    impl Write for SharedWriter {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(bytes);
            Ok(bytes.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    struct SharedWriterPty {
        reader: Cursor<Vec<u8>>,
        writer: SharedWriter,
        resize_count: Arc<std::sync::atomic::AtomicUsize>,
    }

    impl EventedReadWrite for SharedWriterPty {
        type Reader = Cursor<Vec<u8>>;
        type Writer = SharedWriter;

        unsafe fn register(
            &mut self,
            _: &Arc<Poller>,
            _: PollingEvent,
            _: PollMode,
        ) -> io::Result<()> {
            Ok(())
        }

        fn reregister(&mut self, _: &Arc<Poller>, _: PollingEvent, _: PollMode) -> io::Result<()> {
            Ok(())
        }

        fn deregister(&mut self, _: &Arc<Poller>) -> io::Result<()> {
            Ok(())
        }

        fn reader(&mut self) -> &mut Self::Reader {
            &mut self.reader
        }

        fn writer(&mut self) -> &mut Self::Writer {
            &mut self.writer
        }
    }

    impl EventedPty for SharedWriterPty {
        fn next_child_event(&mut self) -> Option<tty::ChildEvent> {
            None
        }
    }

    impl OnResize for SharedWriterPty {
        fn on_resize(&mut self, _: WindowSize) {
            self.resize_count
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        }
    }

    fn shared_writer_event_loop(
        terminal: Arc<FairMutex<Term<VoidListener>>>,
        reader: Vec<u8>,
    ) -> (
        GraphicsEventLoop<SharedWriterPty, VoidListener>,
        Arc<std::sync::Mutex<Vec<u8>>>,
        Arc<std::sync::atomic::AtomicUsize>,
    ) {
        let written = Arc::new(std::sync::Mutex::new(Vec::new()));
        let resize_count = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let graphics = Arc::new(FairMutex::new(KittyGraphicsStore::default()));
        let graphics_size = Arc::new(FairMutex::new(KittyGraphicsSize {
            columns: 40,
            rows: 3,
            cell_width: 1.0,
            cell_height: 1.0,
        }));
        let event_loop = GraphicsEventLoop::new(
            terminal,
            VoidListener,
            SharedWriterPty {
                reader: Cursor::new(reader),
                writer: SharedWriter(Arc::clone(&written)),
                resize_count: Arc::clone(&resize_count),
            },
            graphics,
            graphics_size,
            crate::ModeSnapshot::new(),
            Arc::new(FairMutex::new(FindState::default())),
            FindResultStore::new(),
            FrameHandoff::new(),
        )
        .expect("construct test graphics event loop");
        (event_loop, written, resize_count)
    }

    #[test]
    fn find_lock_backoff_is_bounded_and_resets_after_progress() {
        let mut find = PendingFindBegin {
            generation: 1,
            regex: None,
            matches: Vec::new(),
            next_start: None,
            search_end: None,
            epoch: None,
            retry_delay: FIND_RETRY_MIN,
            deferred: VecDeque::new(),
        };

        assert_eq!(find.retry_delay, Duration::from_millis(1));
        find.note_lock_busy();
        assert_eq!(find.retry_delay, Duration::from_millis(2));
        for _ in 0..8 {
            find.note_lock_busy();
        }
        assert_eq!(find.retry_delay, FIND_RETRY_MAX);

        find.note_chunk_progress();
        assert_eq!(find.retry_delay, FIND_RETRY_MIN);
    }

    #[test]
    fn live_pty_output_cancels_pending_find_before_reusing_points() {
        let size = crate::TermSize {
            columns: 40,
            screen_lines: 3,
        };
        let mut config = Config::default();
        config.scrolling_history = 256;
        let terminal = Arc::new(FairMutex::new(Term::new(config, &size, VoidListener)));
        {
            let mut terminal = terminal.lock_unfair();
            let mut parser: Processor = Processor::new();
            let mut output = Vec::new();
            for _ in 0..256 {
                output.extend_from_slice(b"row\r\n");
            }
            parser.advance(&mut *terminal, &output);
        }
        let (mut event_loop, _, _) =
            shared_writer_event_loop(Arc::clone(&terminal), b"live output\r\n".to_vec());
        let results = event_loop.find_results.clone();
        event_loop
            .sender
            .send(GraphicsMsg::Find(FindMessage::Begin {
                generation: 21,
                needle: "needle".to_owned(),
            }))
            .unwrap();

        let mut state = GraphicsEventLoopState::default();
        assert!(event_loop.drain_messages(&mut state));
        assert!(state.pending_find.is_some());

        let mut buffer = [0u8; 128];
        event_loop
            .pty_read(&mut state, &mut buffer)
            .expect("read live output");
        assert_ne!(state.terminal_revision, 0);
        assert!(event_loop.find_state.lock().matches.is_empty());

        assert!(event_loop.drain_messages(&mut state));
        assert!(state.pending_find.is_none());
        assert_eq!(
            results.read(),
            Some(FindCompletion {
                generation: 21,
                kind: crate::KERO_FIND_RESULT_INVALIDATED,
                total: 0,
                selected: -1,
            })
        );
    }

    #[test]
    fn resize_cancels_find_and_reaches_pty_before_following_input() {
        let size = crate::TermSize {
            columns: 40,
            screen_lines: 3,
        };
        let terminal = Arc::new(FairMutex::new(Term::new(
            Config::default(),
            &size,
            VoidListener,
        )));
        let (mut event_loop, written, resize_count) =
            shared_writer_event_loop(Arc::clone(&terminal), Vec::new());
        let results = event_loop.find_results.clone();
        event_loop
            .sender
            .send(GraphicsMsg::Find(FindMessage::Begin {
                generation: 22,
                needle: "needle".to_owned(),
            }))
            .unwrap();
        event_loop
            .sender
            .send(GraphicsMsg::Resize(WindowSize {
                num_lines: 5,
                num_cols: 60,
                cell_width: 1,
                cell_height: 1,
            }))
            .unwrap();
        event_loop
            .sender
            .send(GraphicsMsg::UserInput(Cow::Owned(b"typed".to_vec())))
            .unwrap();

        let terminal_guard = terminal.lock_unfair();
        let mut state = GraphicsEventLoopState::default();
        assert!(event_loop.drain_messages(&mut state));
        assert!(state.pending_find.is_none());
        assert_eq!(resize_count.load(std::sync::atomic::Ordering::SeqCst), 1);
        assert_eq!(
            results.read(),
            Some(FindCompletion {
                generation: 22,
                kind: crate::KERO_FIND_RESULT_INVALIDATED,
                total: 0,
                selected: -1,
            })
        );

        event_loop
            .pty_write(&mut state)
            .expect("write input after resize");
        assert_eq!(written.lock().unwrap().as_slice(), b"typed");
        drop(terminal_guard);
    }

    #[test]
    fn resize_preinvalidates_find_before_a_queued_step_reacquires_terminal() {
        let size = crate::TermSize {
            columns: 40,
            screen_lines: 3,
        };
        let terminal = Arc::new(FairMutex::new(Term::new(
            Config::default(),
            &size,
            VoidListener,
        )));
        {
            let mut terminal = terminal.lock_unfair();
            let mut parser: Processor = Processor::new();
            parser.advance(&mut *terminal, b"needle");
        }
        let (mut event_loop, _, _) = shared_writer_event_loop(Arc::clone(&terminal), Vec::new());
        {
            let mut terminal = terminal.lock_unfair();
            let mut find_state = event_loop.find_state.lock();
            let result = apply_find_message(
                &mut terminal,
                &mut find_state,
                FindMessage::Begin {
                    generation: 60,
                    needle: "needle".to_owned(),
                },
            );
            assert_eq!(result.total, 1);
            event_loop.find_results.publish(
                result.generation,
                result.kind,
                result.total,
                result.selected,
            );
        }

        let mut terminal_guard = terminal.lock_unfair();
        let sender = event_loop.sender.clone();
        let handoff = event_loop.frame_handoff.clone();
        let find_state = event_loop.find_state.clone();
        let results = event_loop.find_results.clone();
        sender
            .send(GraphicsMsg::Find(FindMessage::Step {
                generation: 61,
                forward: true,
            }))
            .unwrap();

        let (done_tx, done_rx) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            let mut state = GraphicsEventLoopState::default();
            let completed = event_loop.drain_messages(&mut state);
            done_tx.send(completed).unwrap();
        });
        let deadline = Instant::now() + Duration::from_secs(1);
        while !handoff.worker_waiting() && Instant::now() < deadline {
            std::thread::yield_now();
        }
        assert!(
            handoff.worker_waiting(),
            "Step must be waiting for terminal"
        );

        // This is the race window: Step has already passed its queue flush,
        // while the worker is waiting for the terminal lock. Invalidate the
        // shared points before mutating the grid and enqueue both barriers
        // while the lock is still held.
        let preinvalidated_generation = find_state
            .lock()
            .invalidate()
            .expect("completed Find should have an active generation");
        assert_eq!(preinvalidated_generation, 60);
        terminal_guard.resize(crate::TermSize {
            columns: 60,
            screen_lines: 5,
        });
        sender
            .send(GraphicsMsg::InvalidateFindWithGeneration(
                preinvalidated_generation,
            ))
            .unwrap();
        sender
            .send(GraphicsMsg::Resize(WindowSize {
                num_lines: 5,
                num_cols: 60,
                cell_width: 1,
                cell_height: 1,
            }))
            .unwrap();
        drop(terminal_guard);

        assert!(done_rx.recv_timeout(Duration::from_secs(1)).unwrap());
        worker.join().unwrap();
        assert!(find_state.lock().matches.is_empty());
        assert_eq!(
            results.read(),
            Some(FindCompletion {
                generation: 61,
                kind: crate::KERO_FIND_RESULT_INVALIDATED,
                total: 0,
                selected: -1,
            })
        );
    }

    #[test]
    fn late_begin_completion_after_direct_invalidation_publishes_invalidated() {
        let size = crate::TermSize {
            columns: 40,
            screen_lines: 3,
        };
        let terminal = Arc::new(FairMutex::new(Term::new(
            Config::default(),
            &size,
            VoidListener,
        )));
        let (event_loop, _, _) = shared_writer_event_loop(Arc::clone(&terminal), Vec::new());
        {
            let mut find_state = event_loop.find_state.lock();
            find_state.begin(62);
            assert!(find_state.complete(62));
            assert_eq!(find_state.invalidate(), Some(62));
        }

        event_loop.publish_find_result(FindCompletion {
            generation: 62,
            kind: crate::KERO_FIND_RESULT_BEGIN,
            total: 3,
            selected: -1,
        });

        assert_eq!(
            event_loop.find_results.read(),
            Some(FindCompletion {
                generation: 62,
                kind: crate::KERO_FIND_RESULT_INVALIDATED,
                total: 0,
                selected: -1,
            })
        );
    }

    #[test]
    fn pending_begin_invalidation_rejects_late_completion_once() {
        let size = crate::TermSize {
            columns: 40,
            screen_lines: 3,
        };
        let terminal = Arc::new(FairMutex::new(Term::new(
            Config::default(),
            &size,
            VoidListener,
        )));
        let (event_loop, _, _) = shared_writer_event_loop(Arc::clone(&terminal), Vec::new());
        {
            let mut find_state = event_loop.find_state.lock();
            find_state.begin(63);
            assert!(!find_state.result_valid);
            assert_eq!(find_state.invalidate(), Some(63));
            assert!(find_state.result_invalidated);

            // This is the last-chunk interleaving: the direct mutation has
            // already invalidated the pending generation, but the worker is
            // only now trying to commit its detached match vector.
            assert!(!find_state.complete(63));
            assert_eq!(find_state.invalidate(), None);
        }

        event_loop.publish_find_result(FindCompletion {
            generation: 63,
            kind: crate::KERO_FIND_RESULT_BEGIN,
            total: 3,
            selected: -1,
        });

        assert_eq!(
            event_loop.find_results.read(),
            Some(FindCompletion {
                generation: 63,
                kind: crate::KERO_FIND_RESULT_INVALIDATED,
                total: 0,
                selected: -1,
            })
        );

        // A duplicate barrier or repeated PTY mutation is a no-op for the
        // same invalidated generation, not an unbounded replacement.
        event_loop.find_results.publish_invalidated(63);
        assert_eq!(
            event_loop.find_results.read(),
            Some(FindCompletion {
                generation: 63,
                kind: crate::KERO_FIND_RESULT_INVALIDATED,
                total: 0,
                selected: -1,
            })
        );
    }

    #[test]
    fn queued_step_before_invalidation_barrier_publishes_active_generation() {
        let size = crate::TermSize {
            columns: 40,
            screen_lines: 3,
        };
        let terminal = Arc::new(FairMutex::new(Term::new(
            Config::default(),
            &size,
            VoidListener,
        )));
        let (mut event_loop, _, _) = shared_writer_event_loop(Arc::clone(&terminal), Vec::new());
        {
            let mut find_state = event_loop.find_state.lock();
            find_state.begin(80);
            assert!(find_state.complete(80));
            event_loop
                .find_results
                .publish(80, crate::KERO_FIND_RESULT_BEGIN, 2, -1);
            assert_eq!(find_state.invalidate(), Some(80));
        }
        event_loop
            .sender
            .send(GraphicsMsg::Find(FindMessage::Step {
                generation: 81,
                forward: true,
            }))
            .unwrap();
        event_loop
            .sender
            .send(GraphicsMsg::InvalidateFindWithGeneration(80))
            .unwrap();
        event_loop
            .sender
            .send(GraphicsMsg::Resize(WindowSize {
                num_lines: 5,
                num_cols: 60,
                cell_width: 1,
                cell_height: 1,
            }))
            .unwrap();

        let mut state = GraphicsEventLoopState::default();
        assert!(event_loop.drain_messages(&mut state));
        assert!(event_loop.find_state.lock().matches.is_empty());
        assert_eq!(
            event_loop.find_results.read(),
            Some(FindCompletion {
                generation: 81,
                kind: crate::KERO_FIND_RESULT_INVALIDATED,
                total: 0,
                selected: -1,
            })
        );
    }

    #[test]
    fn resize_invalidates_completed_find_before_step() {
        let size = crate::TermSize {
            columns: 40,
            screen_lines: 3,
        };
        let terminal = Arc::new(FairMutex::new(Term::new(
            Config::default(),
            &size,
            VoidListener,
        )));
        {
            let mut terminal = terminal.lock_unfair();
            let mut parser: Processor = Processor::new();
            parser.advance(&mut *terminal, b"needle");
        }
        let (mut event_loop, _, resize_count) =
            shared_writer_event_loop(Arc::clone(&terminal), Vec::new());
        let results = event_loop.find_results.clone();
        event_loop
            .sender
            .send(GraphicsMsg::Find(FindMessage::Begin {
                generation: 30,
                needle: "needle".to_owned(),
            }))
            .unwrap();
        let mut state = GraphicsEventLoopState::default();
        assert!(event_loop.drain_messages(&mut state));
        assert_eq!(event_loop.find_state.lock().matches.len(), 1);

        event_loop
            .sender
            .send(GraphicsMsg::Resize(WindowSize {
                num_lines: 5,
                num_cols: 60,
                cell_width: 1,
                cell_height: 1,
            }))
            .unwrap();
        assert!(event_loop.drain_messages(&mut state));
        assert_eq!(resize_count.load(std::sync::atomic::Ordering::SeqCst), 1);
        assert!(event_loop.find_state.lock().matches.is_empty());
        assert_eq!(
            results.read(),
            Some(FindCompletion {
                generation: 30,
                kind: crate::KERO_FIND_RESULT_INVALIDATED,
                total: 0,
                selected: -1,
            })
        );

        event_loop
            .sender
            .send(GraphicsMsg::Find(FindMessage::Step {
                generation: 31,
                forward: true,
            }))
            .unwrap();
        assert!(event_loop.drain_messages(&mut state));
        assert_eq!(
            results.read(),
            Some(FindCompletion {
                generation: 31,
                kind: crate::KERO_FIND_RESULT_INVALIDATED,
                total: 0,
                selected: -1,
            })
        );
    }

    #[test]
    fn live_pty_output_replaces_completed_find_with_same_generation_invalidation() {
        let size = crate::TermSize {
            columns: 40,
            screen_lines: 3,
        };
        let terminal = Arc::new(FairMutex::new(Term::new(
            Config::default(),
            &size,
            VoidListener,
        )));
        {
            let mut terminal = terminal.lock_unfair();
            let mut parser: Processor = Processor::new();
            parser.advance(&mut *terminal, b"needle");
        }
        let (mut event_loop, _, _) =
            shared_writer_event_loop(Arc::clone(&terminal), b"live output\r\n".to_vec());
        event_loop
            .sender
            .send(GraphicsMsg::Find(FindMessage::Begin {
                generation: 40,
                needle: "needle".to_owned(),
            }))
            .unwrap();
        let mut state = GraphicsEventLoopState::default();
        assert!(event_loop.drain_messages(&mut state));
        assert_eq!(
            event_loop.find_results.read(),
            Some(FindCompletion {
                generation: 40,
                kind: crate::KERO_FIND_RESULT_BEGIN,
                total: 1,
                selected: -1,
            })
        );
        assert_eq!(event_loop.find_state.lock().matches.len(), 1);

        let mut buffer = [0u8; 128];
        event_loop
            .pty_read(&mut state, &mut buffer)
            .expect("read live output");
        assert!(event_loop.find_state.lock().matches.is_empty());
        assert_eq!(
            event_loop.find_results.read(),
            Some(FindCompletion {
                generation: 40,
                kind: crate::KERO_FIND_RESULT_INVALIDATED,
                total: 0,
                selected: -1,
            })
        );
    }

    #[test]
    fn queued_find_invalidation_clears_completed_state_before_following_input() {
        let size = crate::TermSize {
            columns: 40,
            screen_lines: 3,
        };
        let terminal = Arc::new(FairMutex::new(Term::new(
            Config::default(),
            &size,
            VoidListener,
        )));
        {
            let mut terminal = terminal.lock_unfair();
            let mut parser: Processor = Processor::new();
            parser.advance(&mut *terminal, b"needle");
        }
        let (mut event_loop, _, _) = shared_writer_event_loop(Arc::clone(&terminal), Vec::new());
        event_loop
            .sender
            .send(GraphicsMsg::Find(FindMessage::Begin {
                generation: 50,
                needle: "needle".to_owned(),
            }))
            .unwrap();
        let mut state = GraphicsEventLoopState::default();
        assert!(event_loop.drain_messages(&mut state));
        assert_eq!(event_loop.find_state.lock().matches.len(), 1);

        event_loop.sender.send(GraphicsMsg::InvalidateFind).unwrap();
        event_loop
            .sender
            .send(GraphicsMsg::UserInput(Cow::Owned(b"\x0c".to_vec())))
            .unwrap();
        assert!(event_loop.drain_messages(&mut state));

        assert!(event_loop.find_state.lock().matches.is_empty());
        assert_eq!(
            event_loop.find_results.read(),
            Some(FindCompletion {
                generation: 50,
                kind: crate::KERO_FIND_RESULT_INVALIDATED,
                total: 0,
                selected: -1,
            })
        );
        assert_eq!(state.write_list.pop_front().unwrap().as_ref(), b"\x0c");
    }

    #[test]
    fn stopping_synchronized_parser_publishes_buffered_mode() {
        let size = crate::TermSize {
            columns: 40,
            screen_lines: 3,
        };
        let mut terminal = Term::new(Config::default(), &size, VoidListener);
        let mut parser: Processor = Processor::new();
        parser.advance(&mut terminal, b"\x1b[?2026h\x1b[?1049h\x1b[?1002h");
        let snapshot = crate::ModeSnapshot::new();

        stop_sync_and_publish_mode(&mut parser, &mut terminal, &snapshot);

        assert_eq!(
            snapshot.load(),
            crate::MODE_ALT_SCREEN
                | crate::MODE_MOUSE
                | crate::MODE_MOUSE_DRAG
                | crate::MODE_ALTERNATE_SCROLL
        );
    }

    #[test]
    fn kitty_commands_are_committed_before_following_items_capture_context() {
        let term_size = crate::TermSize {
            columns: 40,
            screen_lines: 5,
        };
        let terminal = Arc::new(FairMutex::new(Term::new(
            Config::default(),
            &term_size,
            VoidListener,
        )));
        let graphics = Arc::new(FairMutex::new(KittyGraphicsStore::default()));
        let graphics_size = Arc::new(FairMutex::new(KittyGraphicsSize {
            columns: 40,
            rows: 5,
            cell_width: 1.0,
            cell_height: 1.0,
        }));
        let find_state = Arc::new(FairMutex::new(FindState::default()));
        let mut stream = Vec::new();
        stream.extend_from_slice(b"\x1b_Ga=T,f=32,s=1,v=1,i=20,c=1,r=1;AQID/w==\x1b\\");
        stream.extend_from_slice(b"X");
        stream.extend_from_slice(b"\x1b_Ga=T,f=32,s=1,v=1,i=21,c=1,r=1;AQID/w==\x1b\\");
        let pty = TestPty {
            reader: Cursor::new(stream),
            writer: Vec::new(),
        };
        let mut event_loop = GraphicsEventLoop::new(
            terminal.clone(),
            VoidListener,
            pty,
            graphics.clone(),
            graphics_size,
            crate::ModeSnapshot::new(),
            find_state,
            FindResultStore::new(),
            FrameHandoff::new(),
        )
        .expect("construct test graphics event loop");
        let mut state = GraphicsEventLoopState::default();
        let mut buffer = [0u8; 4096];
        event_loop
            .pty_read(&mut state, &mut buffer)
            .expect("read test Kitty stream");

        let term = terminal.lock_unfair();
        assert_eq!(term.grid().cursor.point.column.0, 3);
        assert_eq!(term.grid().cursor.point.line.0, 2);
        drop(term);

        let graphics = graphics.lock_unfair();
        let placements =
            graphics
                .state
                .render_placements(0, 0, 5, 40, KittyGraphicsScreen::Primary);
        assert_eq!(
            placements
                .iter()
                .find(|placement| placement.image_id == 20)
                .map(|placement| (placement.column, placement.viewport_row)),
            Some((0, 0))
        );
        assert_eq!(
            placements
                .iter()
                .find(|placement| placement.image_id == 21)
                .map(|placement| (placement.column, placement.viewport_row)),
            Some((2, 1))
        );
    }

    #[test]
    fn frame_request_does_not_park_the_pty_worker_before_terminal_lock() {
        let terminal = Arc::new(FairMutex::new(0usize));
        let handoff = FrameHandoff::new();
        handoff.request();
        let worker_terminal = Arc::clone(&terminal);
        let worker_handoff = handoff.clone();
        let (acquired_tx, acquired_rx) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            *lock_terminal_after_frame_handoff(&worker_handoff, &worker_terminal) = 1;
            acquired_tx.send(()).unwrap();
        });

        assert!(acquired_rx.recv_timeout(Duration::from_secs(1)).is_ok());
        worker.join().unwrap();
        assert_eq!(*terminal.lock_unfair(), 1);
    }

    #[test]
    fn frame_lock_cannot_bypass_a_worker_waiting_for_its_terminal_turn() {
        let terminal = Arc::new(FairMutex::new(0usize));
        let handoff = FrameHandoff::new();
        let lease = terminal.lease();
        let worker_terminal = Arc::clone(&terminal);
        let worker_handoff = handoff.clone();
        let worker = std::thread::spawn(move || {
            *lock_terminal_after_frame_handoff(&worker_handoff, &worker_terminal) = 1;
        });

        let deadline = Instant::now() + Duration::from_secs(1);
        while !handoff.worker_waiting() && Instant::now() < deadline {
            std::thread::yield_now();
        }
        assert!(handoff.worker_waiting());
        assert_eq!(handoff.lock_turn(), LOCK_TURN_WORKER);
        assert!(handoff.try_reserve_frame_lock().is_none());

        drop(lease);
        worker.join().unwrap();
        assert_eq!(*terminal.lock_unfair(), 1);
    }

    #[test]
    fn completed_frame_turn_promotes_waiting_worker_over_continuous_frames() {
        let terminal = Arc::new(FairMutex::new(0usize));
        let handoff = FrameHandoff::new();
        handoff.request();
        let mut frame_turn = handoff
            .try_reserve_frame_lock()
            .expect("frame should reserve an idle turn");
        frame_turn.hold_for_frame();
        let terminal_lease = terminal.lease();

        let worker_handoff = handoff.clone();
        let worker_terminal = Arc::clone(&terminal);
        let (worker_started_tx, worker_started_rx) = mpsc::channel();
        let (worker_done_tx, worker_done_rx) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            worker_started_tx.send(()).unwrap();
            *lock_terminal_after_frame_handoff(&worker_handoff, &worker_terminal) = 1;
            worker_done_tx.send(()).unwrap();
        });

        worker_started_rx
            .recv_timeout(Duration::from_secs(1))
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(1);
        while !handoff.worker_waiting() && Instant::now() < deadline {
            std::thread::yield_now();
        }
        assert!(handoff.worker_waiting());
        assert!(matches!(
            worker_done_rx.try_recv(),
            Err(TryRecvError::Empty)
        ));

        handoff.finish();
        // A new frame request cannot reclaim the turn while the worker is
        // waiting. This is the starvation regression: request it repeatedly.
        for _ in 0..100 {
            handoff.request();
            assert!(handoff.try_reserve_frame_lock().is_none());
            std::thread::yield_now();
        }
        drop(terminal_lease);
        worker_done_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        worker.join().unwrap();
        assert_eq!(*terminal.lock_unfair(), 1);
        assert!(handoff.try_reserve_frame_lock().is_some());
        handoff.finish();
    }

    #[test]
    fn user_input_clears_selection_scrolls_bottom_and_queues_bytes() {
        let size = crate::TermSize {
            columns: 40,
            screen_lines: 3,
        };
        let mut terminal = Term::new(Config::default(), &size, VoidListener);
        let mut parser: Processor = Processor::new();
        parser.advance(&mut terminal, b"one\r\ntwo\r\nthree\r\nfour");
        terminal.scroll_display(Scroll::Delta(1));
        terminal.selection = Some(Selection::new(
            SelectionType::Simple,
            Point::new(Line(0), Column(0)),
            Side::Left,
        ));
        let mut state = GraphicsEventLoopState::default();

        let effect = apply_message(
            Some(&mut terminal),
            &mut state,
            GraphicsMsg::UserInput(Cow::Owned(b"typed".to_vec())),
        );

        assert!(matches!(effect, MessageEffect::Continue { wakeup: true }));
        assert!(terminal.selection.is_none());
        assert_eq!(terminal.grid().display_offset(), 0);
        assert_eq!(state.write_list.pop_front().unwrap().as_ref(), b"typed");
    }

    #[test]
    fn frame_request_does_not_delay_user_input_enqueue() {
        let size = crate::TermSize {
            columns: 40,
            screen_lines: 3,
        };
        let terminal = Arc::new(FairMutex::new(Term::new(
            Config::default(),
            &size,
            VoidListener,
        )));
        let handoff = FrameHandoff::new();
        handoff.request();
        let mut frame_turn = handoff
            .try_reserve_frame_lock()
            .expect("frame should reserve an idle turn");
        frame_turn.hold_for_frame();

        let graphics = Arc::new(FairMutex::new(KittyGraphicsStore::default()));
        let graphics_size = Arc::new(FairMutex::new(KittyGraphicsSize {
            columns: 40,
            rows: 3,
            cell_width: 1.0,
            cell_height: 1.0,
        }));
        let event_loop = GraphicsEventLoop::new(
            terminal,
            VoidListener,
            TestPty {
                reader: Cursor::new(Vec::new()),
                writer: Vec::new(),
            },
            graphics,
            graphics_size,
            crate::ModeSnapshot::new(),
            Arc::new(FairMutex::new(FindState::default())),
            FindResultStore::new(),
            handoff.clone(),
        )
        .expect("construct test graphics event loop");
        event_loop
            .sender
            .send(GraphicsMsg::UserInput(Cow::Owned(b"typed".to_vec())))
            .unwrap();

        let (done_tx, done_rx) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            let mut event_loop = event_loop;
            let mut state = GraphicsEventLoopState::default();
            let result = event_loop.drain_messages(&mut state);
            done_tx.send((result, state)).unwrap();
        });

        // The frame keeps its lock turn, so a regression that routes this
        // message through the blocking terminal path would not complete.
        let result = done_rx.recv_timeout(Duration::from_millis(100));
        handoff.finish();
        drop(frame_turn);
        worker.join().unwrap();

        let (ok, mut state) = result.expect("user input enqueue must not wait for the frame");
        assert!(ok);
        assert_eq!(state.write_list.pop_front().unwrap().as_ref(), b"typed");
        assert!(state.pending_user_input_adjustment);
    }

    #[test]
    fn no_echo_input_finishes_adjustment_after_pty_write() {
        let size = crate::TermSize {
            columns: 40,
            screen_lines: 3,
        };
        let terminal = Arc::new(FairMutex::new(Term::new(
            Config::default(),
            &size,
            VoidListener,
        )));
        {
            let mut terminal = terminal.lock_unfair();
            let mut parser: Processor = Processor::new();
            parser.advance(&mut *terminal, b"one\r\ntwo\r\nthree\r\nfour");
            terminal.scroll_display(Scroll::Delta(1));
            terminal.selection = Some(Selection::new(
                SelectionType::Simple,
                Point::new(Line(0), Column(0)),
                Side::Left,
            ));
        }

        let graphics = Arc::new(FairMutex::new(KittyGraphicsStore::default()));
        let graphics_size = Arc::new(FairMutex::new(KittyGraphicsSize {
            columns: 40,
            rows: 3,
            cell_width: 1.0,
            cell_height: 1.0,
        }));
        let mut event_loop = GraphicsEventLoop::new(
            terminal.clone(),
            VoidListener,
            TestPty {
                reader: Cursor::new(Vec::new()),
                writer: Vec::new(),
            },
            graphics,
            graphics_size,
            crate::ModeSnapshot::new(),
            Arc::new(FairMutex::new(FindState::default())),
            FindResultStore::new(),
            FrameHandoff::new(),
        )
        .expect("construct test graphics event loop");

        let mut state = GraphicsEventLoopState::default();
        state.write_list.push_back(Cow::Owned(b"typed".to_vec()));
        state.pending_user_input_adjustment = true;

        // The empty reader models a password/raw-input command with no echo.
        // The adjustment must run after the write, without waiting for a read
        // event or synchronized-parser timeout.
        event_loop
            .pty_write(&mut state)
            .expect("write no-echo input");
        assert!(!state.needs_write());
        assert!(event_loop.finish_user_input_after_write(&mut state));
        assert!(!state.pending_user_input_adjustment);
        assert_eq!(event_loop.pty.writer, b"typed");

        let terminal = terminal.lock_unfair();
        assert!(terminal.selection.is_none());
        assert_eq!(terminal.grid().display_offset(), 0);
    }

    #[test]
    fn user_input_at_bottom_without_selection_does_not_request_wakeup() {
        let size = crate::TermSize {
            columns: 40,
            screen_lines: 3,
        };
        let mut terminal = Term::new(Config::default(), &size, VoidListener);
        let mut state = GraphicsEventLoopState::default();

        let effect = apply_message(
            Some(&mut terminal),
            &mut state,
            GraphicsMsg::UserInput(Cow::Owned(b"typed".to_vec())),
        );

        assert!(matches!(effect, MessageEffect::Continue { wakeup: false }));
        assert_eq!(state.write_list.pop_front().unwrap().as_ref(), b"typed");
    }

    #[test]
    fn async_clear_selection_does_not_scroll_and_only_reports_a_change_once() {
        let size = crate::TermSize {
            columns: 40,
            screen_lines: 3,
        };
        let mut terminal = Term::new(Config::default(), &size, VoidListener);
        let mut parser: Processor = Processor::new();
        parser.advance(&mut terminal, b"one\r\ntwo\r\nthree\r\nfour");
        terminal.scroll_display(Scroll::Delta(1));
        terminal.selection = Some(Selection::new(
            SelectionType::Simple,
            Point::new(Line(0), Column(0)),
            Side::Left,
        ));
        let before_offset = terminal.grid().display_offset();
        let mut state = GraphicsEventLoopState::default();

        let effect = apply_message(Some(&mut terminal), &mut state, GraphicsMsg::ClearSelection);
        assert!(matches!(effect, MessageEffect::Continue { wakeup: true }));
        assert!(terminal.selection.is_none());
        assert_eq!(terminal.grid().display_offset(), before_offset);
        let effect = apply_message(Some(&mut terminal), &mut state, GraphicsMsg::ClearSelection);
        assert!(matches!(effect, MessageEffect::Continue { wakeup: false }));
        assert_eq!(terminal.grid().display_offset(), before_offset);
    }

    #[test]
    fn async_clear_selection_stays_before_following_control_input() {
        let (sender, receiver) = mpsc::channel();
        let poller = Arc::new(Poller::new().expect("test poller should be available"));
        let notifier = GraphicsNotifier(GraphicsEventLoopSender { sender, poller });

        notifier.clear_selection_async();
        notifier.notify(b"\x1b[I".to_vec());

        assert!(matches!(
            receiver.recv().unwrap(),
            GraphicsMsg::ClearSelection
        ));
        match receiver.recv().unwrap() {
            GraphicsMsg::Input(bytes) => assert_eq!(bytes.as_ref(), b"\x1b[I"),
            message => panic!("expected control input after clear, got {message:?}"),
        }
    }

    #[test]
    fn control_input_only_queues_bytes_and_preserves_viewport_state() {
        let size = crate::TermSize {
            columns: 40,
            screen_lines: 3,
        };
        let mut terminal = Term::new(Config::default(), &size, VoidListener);
        let mut parser: Processor = Processor::new();
        parser.advance(&mut terminal, b"one\r\ntwo\r\nthree\r\nfour");
        terminal.scroll_display(Scroll::Delta(1));
        terminal.selection = Some(Selection::new(
            SelectionType::Simple,
            Point::new(Line(0), Column(0)),
            Side::Left,
        ));
        let mut state = GraphicsEventLoopState::default();

        let effect = apply_message::<VoidListener>(
            None,
            &mut state,
            GraphicsMsg::Input(Cow::Owned(b"\x1b[I".to_vec())),
        );

        assert!(matches!(effect, MessageEffect::Continue { wakeup: false }));
        let effect = apply_message::<VoidListener>(
            None,
            &mut state,
            GraphicsMsg::Input(Cow::Owned(b"second".to_vec())),
        );
        assert!(matches!(effect, MessageEffect::Continue { wakeup: false }));
        assert!(terminal.selection.is_some());
        assert_eq!(terminal.grid().display_offset(), 1);
        assert_eq!(state.write_list.pop_front().unwrap().as_ref(), b"\x1b[I");
        assert_eq!(state.write_list.pop_front().unwrap().as_ref(), b"second");
    }

    #[test]
    fn find_ahead_of_user_input_writes_bytes_before_waiting_for_terminal() {
        let size = crate::TermSize {
            columns: 40,
            screen_lines: 3,
        };
        let terminal = Arc::new(FairMutex::new(Term::new(
            Config::default(),
            &size,
            VoidListener,
        )));
        let terminal_guard = terminal.lock_unfair();
        let written = Arc::new(std::sync::Mutex::new(Vec::new()));
        let graphics = Arc::new(FairMutex::new(KittyGraphicsStore::default()));
        let graphics_size = Arc::new(FairMutex::new(KittyGraphicsSize {
            columns: 40,
            rows: 3,
            cell_width: 1.0,
            cell_height: 1.0,
        }));
        let event_loop = GraphicsEventLoop::new(
            terminal.clone(),
            VoidListener,
            SharedWriterPty {
                reader: Cursor::new(Vec::new()),
                writer: SharedWriter(Arc::clone(&written)),
                resize_count: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
            },
            graphics,
            graphics_size,
            crate::ModeSnapshot::new(),
            Arc::new(FairMutex::new(FindState::default())),
            FindResultStore::new(),
            FrameHandoff::new(),
        )
        .expect("construct test graphics event loop");
        event_loop
            .sender
            .send(GraphicsMsg::Find(FindMessage::Begin {
                generation: 7,
                needle: "needle".to_owned(),
            }))
            .unwrap();
        event_loop
            .sender
            .send(GraphicsMsg::UserInput(Cow::Owned(b"typed".to_vec())))
            .unwrap();

        let (done_tx, done_rx) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            let mut event_loop = event_loop;
            let mut state = GraphicsEventLoopState::default();
            loop {
                let result = event_loop.drain_messages(&mut state);
                if !result {
                    done_tx.send(false).unwrap();
                    return;
                }
                if state.pending_find.is_none() && event_loop.receiver.peek().is_none() {
                    done_tx.send(true).unwrap();
                    return;
                }
                std::thread::yield_now();
            }
        });

        let deadline = Instant::now() + Duration::from_millis(100);
        while written.lock().unwrap().as_slice() != b"typed" && Instant::now() < deadline {
            std::thread::yield_now();
        }
        assert_eq!(written.lock().unwrap().as_slice(), b"typed");
        assert!(matches!(done_rx.try_recv(), Err(TryRecvError::Empty)));

        drop(terminal_guard);
        assert!(done_rx.recv_timeout(Duration::from_secs(1)).unwrap());
        worker.join().unwrap();
    }

    #[test]
    fn find_does_not_block_input_after_a_control_barrier() {
        let size = crate::TermSize {
            columns: 40,
            screen_lines: 3,
        };
        let terminal = Arc::new(FairMutex::new(Term::new(
            Config::default(),
            &size,
            VoidListener,
        )));
        let terminal_guard = terminal.lock_unfair();
        let (mut event_loop, written, _) =
            shared_writer_event_loop(Arc::clone(&terminal), Vec::new());
        event_loop
            .sender
            .send(GraphicsMsg::Find(FindMessage::Begin {
                generation: 8,
                needle: "needle".to_owned(),
            }))
            .unwrap();
        event_loop.sender.send(GraphicsMsg::ClearSelection).unwrap();
        event_loop
            .sender
            .send(GraphicsMsg::UserInput(Cow::Owned(b"typed".to_vec())))
            .unwrap();

        let (done_tx, done_rx) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            let mut state = GraphicsEventLoopState::default();
            loop {
                if !event_loop.drain_messages(&mut state) {
                    done_tx.send(false).unwrap();
                    return;
                }
                if state.pending_find.is_none() && event_loop.receiver.peek().is_none() {
                    done_tx.send(true).unwrap();
                    return;
                }
                std::thread::yield_now();
            }
        });

        let deadline = Instant::now() + Duration::from_millis(100);
        while written.lock().unwrap().as_slice() != b"typed" && Instant::now() < deadline {
            std::thread::yield_now();
        }
        assert_eq!(written.lock().unwrap().as_slice(), b"typed");
        assert!(matches!(done_rx.try_recv(), Err(TryRecvError::Empty)));

        drop(terminal_guard);
        assert!(done_rx.recv_timeout(Duration::from_secs(1)).unwrap());
        worker.join().unwrap();
    }

    #[test]
    fn find_does_not_block_following_input_after_the_first_write() {
        let size = crate::TermSize {
            columns: 40,
            screen_lines: 3,
        };
        let terminal = Arc::new(FairMutex::new(Term::new(
            Config::default(),
            &size,
            VoidListener,
        )));
        let terminal_guard = terminal.lock_unfair();
        let (mut event_loop, written, _) =
            shared_writer_event_loop(Arc::clone(&terminal), Vec::new());
        event_loop
            .sender
            .send(GraphicsMsg::Find(FindMessage::Begin {
                generation: 9,
                needle: "needle".to_owned(),
            }))
            .unwrap();
        event_loop
            .sender
            .send(GraphicsMsg::UserInput(Cow::Owned(b"first".to_vec())))
            .unwrap();
        let sender = event_loop.sender.clone();

        let (done_tx, done_rx) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            let mut state = GraphicsEventLoopState::default();
            loop {
                if !event_loop.drain_messages(&mut state) {
                    done_tx.send(false).unwrap();
                    return;
                }
                if state.pending_find.is_none() && event_loop.receiver.peek().is_none() {
                    done_tx.send(true).unwrap();
                    return;
                }
                std::thread::yield_now();
            }
        });

        let deadline = Instant::now() + Duration::from_millis(100);
        while written.lock().unwrap().as_slice() != b"first" && Instant::now() < deadline {
            std::thread::yield_now();
        }
        assert_eq!(written.lock().unwrap().as_slice(), b"first");
        sender
            .send(GraphicsMsg::UserInput(Cow::Owned(b"second".to_vec())))
            .unwrap();

        let deadline = Instant::now() + Duration::from_millis(100);
        while written.lock().unwrap().as_slice() != b"firstsecond" && Instant::now() < deadline {
            std::thread::yield_now();
        }
        assert_eq!(written.lock().unwrap().as_slice(), b"firstsecond");
        assert!(matches!(done_rx.try_recv(), Err(TryRecvError::Empty)));

        drop(terminal_guard);
        assert!(done_rx.recv_timeout(Duration::from_secs(1)).unwrap());
        worker.join().unwrap();
    }

    #[test]
    fn find_worker_messages_report_generation_and_preserve_navigation_semantics() {
        let size = crate::TermSize {
            columns: 40,
            screen_lines: 3,
        };
        let mut terminal = Term::new(Config::default(), &size, VoidListener);
        let mut parser: Processor = Processor::new();
        parser.advance(&mut terminal, b"two one two");
        let mut find = FindState::default();

        let result = apply_find_message(
            &mut terminal,
            &mut find,
            FindMessage::Begin {
                generation: 7,
                needle: "two".to_owned(),
            },
        );
        assert_eq!(result.generation, 7);
        assert_eq!(result.kind, crate::KERO_FIND_RESULT_BEGIN);
        assert_eq!(result.total, 2);
        assert_eq!(result.selected, -1);
        assert!(terminal.selection.is_none());

        let result = apply_find_message(
            &mut terminal,
            &mut find,
            FindMessage::Step {
                generation: 8,
                forward: true,
            },
        );
        assert_eq!(result.kind, crate::KERO_FIND_RESULT_STEP);
        assert_eq!(result.total, 2);
        assert_eq!(result.selected, 0);
        assert!(terminal.selection.is_some());

        let result = apply_find_message(
            &mut terminal,
            &mut find,
            FindMessage::Step {
                generation: 9,
                forward: true,
            },
        );
        assert_eq!(result.selected, 1);

        let result = apply_find_message(
            &mut terminal,
            &mut find,
            FindMessage::End { generation: 10 },
        );
        assert_eq!(result.kind, crate::KERO_FIND_RESULT_END);
        assert_eq!(result.total, 0);
        assert_eq!(result.selected, -1);
        assert!(terminal.selection.is_none());
    }

    #[test]
    fn step_after_unconsumed_invalidation_requests_active_generation_refresh() {
        let size = crate::TermSize {
            columns: 40,
            screen_lines: 3,
        };
        let mut terminal = Term::new(Config::default(), &size, VoidListener);
        let mut parser: Processor = Processor::new();
        parser.advance(&mut terminal, b"needle");
        let mut find = FindState::default();
        let results = FindResultStore::new();

        let begin = apply_find_message(
            &mut terminal,
            &mut find,
            FindMessage::Begin {
                generation: 20,
                needle: "needle".to_owned(),
            },
        );
        results.publish(begin.generation, begin.kind, begin.total, begin.selected);
        let invalidated_generation = find
            .invalidate()
            .expect("completed result should invalidate");
        results.publish_invalidated(invalidated_generation);

        // The old INVALIDATED result is still in the slot when the UI sends
        // its next Step. The active generation must keep the invalid state
        // visible instead of replacing it with STEP/0.
        let step = apply_find_message(
            &mut terminal,
            &mut find,
            FindMessage::Step {
                generation: 21,
                forward: true,
            },
        );
        assert_eq!(
            step,
            FindCompletion {
                generation: 21,
                kind: crate::KERO_FIND_RESULT_INVALIDATED,
                total: 0,
                selected: -1,
            }
        );
        assert_eq!(find.result_generation, 21);
        assert!(!find.result_valid);
        results.publish_invalidated(step.generation);
        assert_eq!(results.read(), Some(step));

        // A late stale Step cannot move the state backwards or replace the
        // active invalidation.
        let stale = apply_find_message(
            &mut terminal,
            &mut find,
            FindMessage::Step {
                generation: 20,
                forward: true,
            },
        );
        assert_eq!(stale.kind, crate::KERO_FIND_RESULT_STEP);
        assert_eq!(stale.total, 0);
        assert_eq!(stale.selected, -1);
        assert_eq!(find.result_generation, 21);
        results.publish(stale.generation, stale.kind, stale.total, stale.selected);
        assert_eq!(results.read(), Some(step));
    }

    #[test]
    fn find_result_store_keeps_the_newest_generation() {
        let store = FindResultStore::new();
        store.publish(9, crate::KERO_FIND_RESULT_STEP, 2, 1);
        store.publish(8, crate::KERO_FIND_RESULT_BEGIN, 99, -1);

        let result = store.read().expect("published find result");
        assert_eq!(result.generation, 9);
        assert_eq!(result.kind, crate::KERO_FIND_RESULT_STEP);
        assert_eq!(result.total, 2);
        assert_eq!(result.selected, 1);
    }

    #[test]
    fn find_result_store_allows_same_generation_invalidation_replacement() {
        let store = FindResultStore::new();
        store.publish(9, crate::KERO_FIND_RESULT_BEGIN, 2, -1);
        store.publish_invalidated(9);

        assert_eq!(
            store.read(),
            Some(FindCompletion {
                generation: 9,
                kind: crate::KERO_FIND_RESULT_INVALIDATED,
                total: 0,
                selected: -1,
            })
        );
    }

    #[test]
    fn find_notifier_queues_fifo_worker_commands_with_generations() {
        let (sender, receiver) = mpsc::channel();
        let poller = Arc::new(Poller::new().expect("test poller should be available"));
        let notifier = GraphicsNotifier(GraphicsEventLoopSender { sender, poller });

        assert!(notifier.find_begin(7, "two".to_owned()));
        assert!(notifier.find_step(8, true));
        assert!(notifier.find_end(9));

        assert!(matches!(
            receiver.recv().unwrap(),
            GraphicsMsg::Find(FindMessage::Begin { generation: 7, needle }) if needle == "two"
        ));
        assert!(matches!(
            receiver.recv().unwrap(),
            GraphicsMsg::Find(FindMessage::Step {
                generation: 8,
                forward: true
            })
        ));
        assert!(matches!(
            receiver.recv().unwrap(),
            GraphicsMsg::Find(FindMessage::End { generation: 9 })
        ));
    }

    #[test]
    fn find_invalidation_stays_before_following_user_input() {
        let (sender, receiver) = mpsc::channel();
        let poller = Arc::new(Poller::new().expect("test poller should be available"));
        let notifier = GraphicsNotifier(GraphicsEventLoopSender { sender, poller });

        notifier.invalidate_find();
        notifier.notify_user(Cow::Owned(b"\x0c".to_vec()));

        assert!(matches!(
            receiver.recv().unwrap(),
            GraphicsMsg::InvalidateFind
        ));
        assert!(matches!(
            receiver.recv().unwrap(),
            GraphicsMsg::UserInput(bytes) if bytes.as_ref() == b"\x0c"
        ));
    }
}

struct Writing {
    source: Cow<'static, [u8]>,
    written: usize,
}

impl Writing {
    fn new(source: Cow<'static, [u8]>) -> Self {
        Self { source, written: 0 }
    }

    fn advance(&mut self, count: usize) {
        self.written += count;
    }

    fn remaining_bytes(&self) -> &[u8] {
        &self.source[self.written..]
    }

    fn finished(&self) -> bool {
        self.written >= self.source.len()
    }
}

#[derive(Clone)]
pub(crate) struct GraphicsEventLoopSender {
    sender: Sender<GraphicsMsg>,
    poller: Arc<Poller>,
}

impl GraphicsEventLoopSender {
    #[cfg(test)]
    pub(crate) fn for_test(sender: Sender<GraphicsMsg>, poller: Arc<Poller>) -> Self {
        Self { sender, poller }
    }

    pub(crate) fn send(&self, message: GraphicsMsg) -> io::Result<()> {
        self.sender
            .send(message)
            .map_err(|error| io::Error::new(ErrorKind::BrokenPipe, error.to_string()))?;
        self.poller.notify()
    }

    pub(crate) fn invalidate_find(&self) -> io::Result<()> {
        self.send(GraphicsMsg::InvalidateFind)
    }

    pub(crate) fn invalidate_find_generation(&self, generation: u64) -> io::Result<()> {
        self.send(GraphicsMsg::InvalidateFindWithGeneration(generation))
    }
}

pub(crate) struct GraphicsNotifier(pub(crate) GraphicsEventLoopSender);

impl GraphicsNotifier {
    #[cfg(test)]
    pub(crate) fn for_test() -> Self {
        let (sender, _receiver) = mpsc::channel();
        let poller = Arc::new(Poller::new().expect("test poller should be available"));
        Self(GraphicsEventLoopSender { sender, poller })
    }

    pub(crate) fn notify_user(&self, bytes: Cow<'static, [u8]>) {
        if !bytes.is_empty() {
            let _ = self.0.send(GraphicsMsg::UserInput(bytes));
        }
    }

    pub(crate) fn clear_selection_async(&self) {
        let _ = self.0.send(GraphicsMsg::ClearSelection);
    }

    pub(crate) fn invalidate_find(&self) {
        let _ = self.0.invalidate_find();
    }

    pub(crate) fn invalidate_find_generation(&self, generation: u64) {
        let _ = self.0.invalidate_find_generation(generation);
    }

    pub(crate) fn find_begin(&self, generation: u64, needle: String) -> bool {
        self.0
            .send(GraphicsMsg::Find(FindMessage::Begin { generation, needle }))
            .is_ok()
    }

    pub(crate) fn find_step(&self, generation: u64, forward: bool) -> bool {
        self.0
            .send(GraphicsMsg::Find(FindMessage::Step {
                generation,
                forward,
            }))
            .is_ok()
    }

    pub(crate) fn find_end(&self, generation: u64) -> bool {
        self.0
            .send(GraphicsMsg::Find(FindMessage::End { generation }))
            .is_ok()
    }
}

impl Notify for GraphicsNotifier {
    fn notify<B>(&self, bytes: B)
    where
        B: Into<Cow<'static, [u8]>>,
    {
        let bytes = bytes.into();
        if !bytes.is_empty() {
            let _ = self.0.send(GraphicsMsg::Input(bytes));
        }
    }
}

impl OnResize for GraphicsNotifier {
    fn on_resize(&mut self, size: WindowSize) {
        let _ = self.0.send(GraphicsMsg::Resize(size));
    }
}

struct PendingKittyCommand {
    command: KittyGraphicsCommand,
    cursor_column: usize,
    cursor_row: usize,
    history_size: usize,
    size: KittyGraphicsSize,
    screen: KittyGraphicsScreen,
    full_screen_scroll_region: bool,
}

#[derive(Default)]
struct GraphicsEventLoopState {
    write_list: VecDeque<Cow<'static, [u8]>>,
    pending_user_input_adjustment: bool,
    pending_find: Option<PendingFindBegin>,
    terminal_revision: u64,
    writing: Option<Writing>,
    parser: ansi::Processor,
    graphics_interceptor: KittyGraphicsInterceptor,
    graphics_cursor_tracker: KittyGraphicsCursorTracker,
}

impl GraphicsEventLoopState {
    fn ensure_next(&mut self) {
        if self.writing.is_none() {
            self.goto_next();
        }
    }

    fn goto_next(&mut self) {
        self.writing = self.write_list.pop_front().map(Writing::new);
    }

    fn take_current(&mut self) -> Option<Writing> {
        self.writing.take()
    }

    fn set_current(&mut self, current: Option<Writing>) {
        self.writing = current;
    }

    fn needs_write(&self) -> bool {
        self.writing.is_some() || !self.write_list.is_empty()
    }
}

struct PeekableReceiver<T> {
    receiver: Receiver<T>,
    buffered: VecDeque<T>,
}

impl<T> PeekableReceiver<T> {
    fn new(receiver: Receiver<T>) -> Self {
        Self {
            receiver,
            buffered: VecDeque::new(),
        }
    }

    fn peek(&mut self) -> Option<&T> {
        if self.buffered.is_empty() {
            if let Ok(message) = self.receiver.try_recv() {
                self.buffered.push_back(message);
            }
        }
        self.buffered.front()
    }

    fn recv(&mut self) -> Option<T> {
        if let Some(message) = self.buffered.pop_front() {
            Some(message)
        } else {
            match self.receiver.try_recv() {
                Err(TryRecvError::Disconnected) => None,
                result => result.ok(),
            }
        }
    }

    fn prepend(&mut self, mut messages: VecDeque<T>) {
        messages.append(&mut self.buffered);
        self.buffered = messages;
    }
}
