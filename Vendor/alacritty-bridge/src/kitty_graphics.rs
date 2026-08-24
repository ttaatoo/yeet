//! Renderer-neutral Kitty graphics protocol support.
//!
//! Adapted from Termy's implementation at
//! https://github.com/lassejlv/termy/tree/d094009217c278701abdecf906dc1903e6b01bc5
//! under the MIT license in `../TERMY_LICENSE`.

use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use flate2::read::ZlibDecoder;
use std::{
    collections::{HashMap, VecDeque},
    io::{Cursor, Read},
    sync::Arc,
};

const MAX_IMAGE_BYTES: usize = 128 * 1024 * 1024;
const MAX_COMMAND_BYTES: usize = MAX_IMAGE_BYTES * 2;
const MAX_DIMENSION: u32 = 32_768;
const MAX_PIXELS: u64 = (MAX_IMAGE_BYTES / 4) as u64;

#[derive(Clone, Copy, Debug)]
pub(crate) struct KittyGraphicsSize {
    pub(crate) columns: usize,
    pub(crate) rows: usize,
    pub(crate) cell_width: f32,
    pub(crate) cell_height: f32,
}

#[derive(Clone, Debug)]
pub(crate) struct KittyGraphicsCommand {
    control: Vec<(char, String)>,
    payload: Vec<u8>,
    oversized: bool,
}

impl KittyGraphicsCommand {
    fn parse(bytes: Vec<u8>, oversized: bool) -> Self {
        let separator = bytes.iter().position(|byte| *byte == b';');
        let (control, payload) = match separator {
            Some(index) => (&bytes[..index], bytes[index + 1..].to_vec()),
            None => (bytes.as_slice(), Vec::new()),
        };
        let control = String::from_utf8_lossy(control)
            .split(',')
            .filter_map(|field| {
                let (key, value) = field.split_once('=')?;
                let mut chars = key.chars();
                let key = chars.next()?;
                (chars.next().is_none() && key.is_ascii()).then(|| (key, value.to_owned()))
            })
            .collect();
        Self {
            control,
            payload,
            oversized,
        }
    }

    fn value(&self, key: char) -> Option<&str> {
        self.control
            .iter()
            .rev()
            .find_map(|(candidate, value)| (*candidate == key).then_some(value.as_str()))
    }

    fn char_value(&self, key: char) -> Option<char> {
        let mut chars = self.value(key)?.chars();
        let value = chars.next()?;
        chars.next().is_none().then_some(value)
    }

    fn u32_value(&self, key: char) -> Option<u32> {
        self.value(key)?.parse().ok()
    }

    fn i32_value(&self, key: char) -> Option<i32> {
        self.value(key)?.parse().ok()
    }
}

#[derive(Clone, Debug)]
pub(crate) enum KittyGraphicsItem {
    Text(Vec<u8>),
    Command(KittyGraphicsCommand),
}

#[derive(Clone, Copy, Debug, Default)]
enum InterceptorState {
    #[default]
    Ground,
    Escape,
    ApcStart {
        c1: bool,
    },
    OtherApc,
    OtherApcEscape,
    Kitty,
    KittyEscape,
}

#[derive(Default)]
pub(crate) struct KittyGraphicsInterceptor {
    state: InterceptorState,
    command: Vec<u8>,
    oversized: bool,
    utf8_continuations: u8,
}

impl KittyGraphicsInterceptor {
    pub(crate) fn process(&mut self, bytes: &[u8]) -> Vec<KittyGraphicsItem> {
        let mut items = Vec::new();
        let mut text = Vec::with_capacity(bytes.len());
        let flush_text = |items: &mut Vec<KittyGraphicsItem>, text: &mut Vec<u8>| {
            if !text.is_empty() {
                items.push(KittyGraphicsItem::Text(std::mem::take(text)));
            }
        };

        for &byte in bytes {
            match self.state {
                InterceptorState::Ground => {
                    if self.utf8_continuations > 0 && (0x80..=0xbf).contains(&byte) {
                        text.push(byte);
                        self.utf8_continuations -= 1;
                        continue;
                    }
                    self.utf8_continuations = 0;
                    match byte {
                        0x1b => self.state = InterceptorState::Escape,
                        0x9f => self.state = InterceptorState::ApcStart { c1: true },
                        _ => {
                            text.push(byte);
                            self.utf8_continuations = match byte {
                                0xc2..=0xdf => 1,
                                0xe0..=0xef => 2,
                                0xf0..=0xf4 => 3,
                                _ => 0,
                            };
                        }
                    }
                }
                InterceptorState::Escape => {
                    if byte == b'_' {
                        self.state = InterceptorState::ApcStart { c1: false };
                    } else if byte == 0x1b {
                        text.push(0x1b);
                    } else {
                        text.extend_from_slice(&[0x1b, byte]);
                        self.state = InterceptorState::Ground;
                    }
                }
                InterceptorState::ApcStart { c1 } => {
                    if byte == b'G' {
                        flush_text(&mut items, &mut text);
                        self.command.clear();
                        self.oversized = false;
                        self.state = InterceptorState::Kitty;
                    } else {
                        if c1 {
                            text.push(0x9f);
                        } else {
                            text.extend_from_slice(b"\x1b_");
                        }
                        text.push(byte);
                        self.state = InterceptorState::OtherApc;
                    }
                }
                InterceptorState::OtherApc => {
                    text.push(byte);
                    if byte == 0x9c {
                        self.state = InterceptorState::Ground;
                    } else if byte == 0x1b {
                        self.state = InterceptorState::OtherApcEscape;
                    }
                }
                InterceptorState::OtherApcEscape => {
                    text.push(byte);
                    if byte == b'\\' || byte == 0x9c {
                        self.state = InterceptorState::Ground;
                    } else if byte != 0x1b {
                        self.state = InterceptorState::OtherApc;
                    }
                }
                InterceptorState::Kitty => {
                    if byte == 0x1b {
                        self.state = InterceptorState::KittyEscape;
                    } else if byte == 0x9c {
                        flush_text(&mut items, &mut text);
                        items.push(KittyGraphicsItem::Command(KittyGraphicsCommand::parse(
                            std::mem::take(&mut self.command),
                            self.oversized,
                        )));
                        self.state = InterceptorState::Ground;
                    } else if self.command.len() < MAX_COMMAND_BYTES {
                        self.command.push(byte);
                    } else {
                        self.oversized = true;
                    }
                }
                InterceptorState::KittyEscape => {
                    if byte == b'\\' {
                        flush_text(&mut items, &mut text);
                        items.push(KittyGraphicsItem::Command(KittyGraphicsCommand::parse(
                            std::mem::take(&mut self.command),
                            self.oversized,
                        )));
                        self.state = InterceptorState::Ground;
                    } else {
                        if self.command.len() + 2 <= MAX_COMMAND_BYTES {
                            self.command.extend_from_slice(&[0x1b, byte]);
                        } else {
                            self.oversized = true;
                        }
                        self.state = InterceptorState::Kitty;
                    }
                }
            }
        }
        flush_text(&mut items, &mut text);
        items
    }
}

#[derive(Clone, Debug)]
struct StoredImage {
    /// 8-bit RGBA, unpacked once so the host does not decode PNG on the
    /// frame path.
    rgba: Arc<[u8]>,
    width: u32,
    height: u32,
    byte_len: usize,
    generation: u64,
}

#[derive(Clone, Debug)]
struct Placement {
    placement_serial: u64,
    screen: KittyGraphicsScreen,
    image_id: u32,
    placement_id: u32,
    anchor_line: i64,
    column: usize,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
    display_columns: u32,
    display_rows: u32,
    occupied_columns: u32,
    occupied_rows: u32,
    x_offset: u32,
    y_offset: u32,
    z_index: i32,
}

#[derive(Clone, Debug)]
struct PendingUpload {
    command: KittyGraphicsCommand,
    decoded: Vec<u8>,
    context: PlacementContext,
}

#[derive(Clone, Copy, Debug)]
struct PlacementContext {
    cursor_column: usize,
    cursor_row: usize,
    history_size: usize,
    size: KittyGraphicsSize,
    screen: KittyGraphicsScreen,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum KittyGraphicsScreen {
    #[default]
    Primary,
    Alternate,
}

impl KittyGraphicsScreen {
    pub(crate) fn from_alternate_screen(alternate_screen: bool) -> Self {
        if alternate_screen {
            Self::Alternate
        } else {
            Self::Primary
        }
    }
}

#[derive(Clone, Debug)]
pub(crate) struct KittyGraphicsRenderPlacement {
    pub(crate) placement_serial: u64,
    pub(crate) image_id: u32,
    pub(crate) placement_id: u32,
    pub(crate) rgba: Arc<[u8]>,
    pub(crate) image_width: u32,
    pub(crate) image_height: u32,
    pub(crate) image_generation: u64,
    pub(crate) viewport_row: i32,
    pub(crate) column: usize,
    pub(crate) source_x: u32,
    pub(crate) source_y: u32,
    pub(crate) source_width: u32,
    pub(crate) source_height: u32,
    pub(crate) display_columns: u32,
    pub(crate) display_rows: u32,
    pub(crate) occupied_columns: u32,
    pub(crate) occupied_rows: u32,
    pub(crate) x_offset: u32,
    pub(crate) y_offset: u32,
    pub(crate) z_index: i32,
}

#[derive(Default)]
pub(crate) struct KittyGraphicsApplyResult {
    pub(crate) response: Option<Vec<u8>>,
    pub(crate) cursor_advance: Option<(u32, u32)>,
    pub(crate) cursor_advance_screen: Option<KittyGraphicsScreen>,
    pub(crate) changed: bool,
}

#[derive(Default)]
pub(crate) struct KittyGraphicsState {
    images: HashMap<u32, StoredImage>,
    placements: Vec<Placement>,
    insertion_order: VecDeque<u32>,
    pending: Option<PendingUpload>,
    next_anonymous_id: u32,
    stored_bytes: usize,
    next_generation: u64,
    next_placement_serial: u64,
}

#[derive(Default)]
pub(crate) struct KittyGraphicsStore {
    pub(crate) state: KittyGraphicsState,
    pub(crate) revision: u64,
}

impl KittyGraphicsStore {
    pub(crate) fn mark_changed(&mut self) {
        self.revision = self.revision.wrapping_add(1).max(1);
    }
}

impl KittyGraphicsState {
    pub(crate) fn apply(
        &mut self,
        command: KittyGraphicsCommand,
        cursor_column: usize,
        cursor_row: usize,
        history_size: usize,
        size: KittyGraphicsSize,
        screen: KittyGraphicsScreen,
    ) -> KittyGraphicsApplyResult {
        let context = PlacementContext {
            cursor_column,
            cursor_row,
            history_size,
            size,
            screen,
        };
        if command.oversized {
            let response_command = self
                .pending
                .take()
                .map_or_else(|| command.clone(), |pending| pending.command);
            return self.failure(
                &response_command,
                "EFBIG:image command exceeds storage limit",
            );
        }

        let action = command.char_value('a').unwrap_or('t');
        if action == 'd' {
            return self.delete(
                &command,
                context.cursor_column,
                context.cursor_row,
                context.history_size,
                context.screen,
            );
        }
        if action == 'p' {
            return self.put(command, context);
        }
        if !matches!(action, 't' | 'T' | 'q') {
            return self.failure(&command, "EINVAL:unsupported graphics action");
        }

        let decoded = match BASE64.decode(&command.payload) {
            Ok(decoded) if decoded.len() <= MAX_IMAGE_BYTES => decoded,
            Ok(_) => {
                let response_command = self
                    .pending
                    .take()
                    .map_or_else(|| command.clone(), |pending| pending.command);
                return self.failure(
                    &response_command,
                    "EFBIG:image payload exceeds storage limit",
                );
            }
            Err(_) => {
                let response_command = self
                    .pending
                    .take()
                    .map_or_else(|| command.clone(), |pending| pending.command);
                return self.failure(&response_command, "EINVAL:invalid base64 payload");
            }
        };

        let more = command.u32_value('m').unwrap_or(0) == 1;
        if let Some(mut pending) = self.pending.take() {
            if pending.decoded.len().saturating_add(decoded.len()) > MAX_IMAGE_BYTES {
                return self.failure(
                    &pending.command,
                    "EFBIG:image payload exceeds storage limit",
                );
            }
            pending.decoded.extend_from_slice(&decoded);
            if more {
                self.pending = Some(pending);
                return KittyGraphicsApplyResult::default();
            }
            let mut first = pending.command;
            for (key, value) in command.control {
                if key != 'm' {
                    first.control.push((key, value));
                }
            }
            return self.finish_upload(first, pending.decoded, pending.context);
        }

        if more {
            self.pending = Some(PendingUpload {
                command,
                decoded,
                context,
            });
            return KittyGraphicsApplyResult::default();
        }
        self.finish_upload(command, decoded, context)
    }

    pub(crate) fn render_placements(
        &self,
        history_size: usize,
        display_offset: usize,
        rows: usize,
        columns: usize,
        screen: KittyGraphicsScreen,
    ) -> Vec<KittyGraphicsRenderPlacement> {
        let history_size = i64::try_from(history_size).unwrap_or(i64::MAX);
        let display_offset = i64::try_from(display_offset).unwrap_or(i64::MAX);
        let rows = i64::try_from(rows).unwrap_or(i64::MAX);
        self.placements
            .iter()
            .filter(|placement| placement.screen == screen)
            .filter_map(|placement| {
                let image = self.images.get(&placement.image_id)?;
                let viewport_row = placement
                    .anchor_line
                    .saturating_sub(history_size)
                    .saturating_add(display_offset);
                let bottom = viewport_row.saturating_add(i64::from(placement.occupied_rows));
                if bottom <= 0
                    || viewport_row >= rows
                    || placement.column >= columns
                    || placement.occupied_columns == 0
                {
                    return None;
                }
                Some(KittyGraphicsRenderPlacement {
                    placement_serial: placement.placement_serial,
                    image_id: placement.image_id,
                    placement_id: placement.placement_id,
                    rgba: image.rgba.clone(),
                    image_width: image.width,
                    image_height: image.height,
                    image_generation: image.generation,
                    viewport_row: i32::try_from(viewport_row).unwrap_or(if viewport_row < 0 {
                        i32::MIN
                    } else {
                        i32::MAX
                    }),
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
                })
            })
            .collect()
    }

    pub(crate) fn has_placements(&self) -> bool {
        !self.placements.is_empty()
    }

    pub(crate) fn clear_screen(&mut self, screen: KittyGraphicsScreen) -> bool {
        let before = self.placements.len();
        self.placements
            .retain(|placement| placement.screen != screen);
        if self
            .pending
            .as_ref()
            .is_some_and(|pending| pending.context.screen == screen)
        {
            self.pending = None;
        }
        before != self.placements.len()
    }

    pub(crate) fn clear_viewport(
        &mut self,
        screen: KittyGraphicsScreen,
        history_size: usize,
        rows: usize,
        columns: usize,
    ) -> bool {
        if rows == 0 || columns == 0 {
            return false;
        }
        let viewport_start = i64::try_from(history_size).unwrap_or(i64::MAX);
        let viewport_end = viewport_start.saturating_add(i64::try_from(rows).unwrap_or(i64::MAX));
        let before = self.placements.len();
        self.placements.retain(|placement| {
            if placement.screen != screen {
                return true;
            }
            let placement_end = placement
                .anchor_line
                .saturating_add(i64::from(placement.occupied_rows));
            let vertically_visible =
                placement.anchor_line < viewport_end && placement_end > viewport_start;
            let horizontally_visible = placement.column < columns && placement.occupied_columns > 0;
            !(vertically_visible && horizontally_visible)
        });
        before != self.placements.len()
    }

    pub(crate) fn scroll_up_without_history(
        &mut self,
        lines: usize,
        screen: KittyGraphicsScreen,
    ) -> bool {
        if lines == 0
            || !self
                .placements
                .iter()
                .any(|placement| placement.screen == screen)
        {
            return false;
        }
        let lines = i64::try_from(lines).unwrap_or(i64::MAX);
        for placement in self
            .placements
            .iter_mut()
            .filter(|placement| placement.screen == screen)
        {
            placement.anchor_line = placement.anchor_line.saturating_sub(lines);
        }
        self.placements.retain(|placement| {
            placement.screen != screen
                || placement
                    .anchor_line
                    .saturating_add(i64::from(placement.occupied_rows))
                    > 0
        });
        true
    }

    pub(crate) fn preserve_primary_across_partial_history_growth(&mut self, lines: usize) -> bool {
        if lines == 0 {
            return false;
        }
        let lines = i64::try_from(lines).unwrap_or(i64::MAX);
        let mut changed = false;
        for placement in self
            .placements
            .iter_mut()
            .filter(|placement| placement.screen == KittyGraphicsScreen::Primary)
        {
            placement.anchor_line = placement.anchor_line.saturating_add(lines);
            changed = true;
        }
        changed
    }

    fn finish_upload(
        &mut self,
        command: KittyGraphicsCommand,
        decoded: Vec<u8>,
        context: PlacementContext,
    ) -> KittyGraphicsApplyResult {
        let data = match self.resolve_transmission_data(&command, decoded) {
            Ok(data) => data,
            Err(error) => return self.failure(&command, &error),
        };
        let data = match command.char_value('o') {
            None => data,
            Some('z') => match decompress_zlib(&data) {
                Ok(data) => data,
                Err(error) => return self.failure(&command, &error),
            },
            Some(_) => return self.failure(&command, "EINVAL:unsupported compression"),
        };
        let (rgba, width, height) = match normalize_image(&command, &data) {
            Ok(image) => image,
            Err(error) => return self.failure(&command, &error),
        };

        if command.char_value('a').unwrap_or('t') == 'q' {
            return self.success(&command, false, None, context.screen);
        }

        let requested_id = command.u32_value('i').unwrap_or(0);
        let image_id = if requested_id == 0 {
            self.allocate_anonymous_id()
        } else {
            requested_id
        };
        self.remove_image(image_id);
        let byte_len = rgba.len();
        self.next_generation = self.next_generation.wrapping_add(1).max(1);
        self.images.insert(
            image_id,
            StoredImage {
                rgba: Arc::from(rgba),
                width,
                height,
                byte_len,
                generation: self.next_generation,
            },
        );
        self.insertion_order.push_back(image_id);
        self.stored_bytes = self.stored_bytes.saturating_add(byte_len);
        if !self.enforce_quota(Some(image_id)) {
            self.remove_image(image_id);
            return self.failure(&command, "ENOSPC:image storage quota exceeded");
        }

        let display = command.char_value('a').unwrap_or('t') == 'T';
        let cursor_advance = if display {
            match self.add_placement(image_id, &command, context) {
                Ok(advance) => advance,
                Err(error) => {
                    self.remove_image(image_id);
                    return self.failure(&command, &error);
                }
            }
        } else {
            None
        };
        self.success(&command, true, cursor_advance, context.screen)
    }

    fn put(
        &mut self,
        command: KittyGraphicsCommand,
        context: PlacementContext,
    ) -> KittyGraphicsApplyResult {
        let image_id = command.u32_value('i').unwrap_or(0);
        if image_id == 0 || !self.images.contains_key(&image_id) {
            return self.failure(&command, "ENOENT:image id not found");
        }
        match self.add_placement(image_id, &command, context) {
            Ok(advance) => self.success(&command, true, advance, context.screen),
            Err(error) => self.failure(&command, &error),
        }
    }

    fn add_placement(
        &mut self,
        image_id: u32,
        command: &KittyGraphicsCommand,
        context: PlacementContext,
    ) -> Result<Option<(u32, u32)>, String> {
        if command.u32_value('U').unwrap_or(0) == 1 {
            return Err("EINVAL:Unicode placeholder placements are not supported".into());
        }
        let image = self
            .images
            .get(&image_id)
            .ok_or_else(|| "ENOENT:image id not found".to_owned())?;
        let source_x = command.u32_value('x').unwrap_or(0).min(image.width);
        let source_y = command.u32_value('y').unwrap_or(0).min(image.height);
        let source_width = command
            .u32_value('w')
            .unwrap_or(image.width.saturating_sub(source_x))
            .min(image.width.saturating_sub(source_x));
        let source_height = command
            .u32_value('h')
            .unwrap_or(image.height.saturating_sub(source_y))
            .min(image.height.saturating_sub(source_y));
        if source_width == 0 || source_height == 0 {
            return Err("EINVAL:empty source rectangle".into());
        }

        let cell_width = context.size.cell_width.max(1.0);
        let cell_height = context.size.cell_height.max(1.0);
        let requested_columns = command.u32_value('c').filter(|value| *value > 0);
        let requested_rows = command.u32_value('r').filter(|value| *value > 0);
        let available_columns = u32::try_from(context.size.columns)
            .unwrap_or(u32::MAX)
            .saturating_sub(u32::try_from(context.cursor_column).unwrap_or(u32::MAX))
            .max(1);
        let available_width = available_columns as f32 * cell_width;

        let mut placed_source_width = source_width;
        let (display_columns, display_rows) = match (requested_columns, requested_rows) {
            (Some(columns), Some(rows)) => (columns, rows),
            (Some(columns), None) => {
                let width = columns as f32 * cell_width;
                let height = width * source_height as f32 / source_width as f32;
                (columns, (height / cell_height).ceil().max(1.0) as u32)
            }
            (None, Some(rows)) => {
                let height = rows as f32 * cell_height;
                let width = height * source_width as f32 / source_height as f32;
                ((width / cell_width).ceil().max(1.0) as u32, rows)
            }
            (None, None) => {
                if source_width as f32 > available_width {
                    placed_source_width = available_width.floor().max(1.0) as u32;
                }
                (
                    ((placed_source_width as f32 / cell_width).ceil().max(1.0) as u32)
                        .min(available_columns),
                    (source_height as f32 / cell_height).ceil().max(1.0) as u32,
                )
            }
        };
        let occupied_columns = display_columns;
        let occupied_rows = display_rows;
        let placement_id = command.u32_value('p').unwrap_or(0);
        if placement_id != 0 {
            self.placements.retain(|placement| {
                placement.screen != context.screen
                    || placement.image_id != image_id
                    || placement.placement_id != placement_id
            });
        }
        self.next_placement_serial = self.next_placement_serial.wrapping_add(1).max(1);
        self.placements.push(Placement {
            placement_serial: self.next_placement_serial,
            screen: context.screen,
            image_id,
            placement_id,
            anchor_line: i64::try_from(context.history_size)
                .unwrap_or(i64::MAX)
                .saturating_add(i64::try_from(context.cursor_row).unwrap_or(i64::MAX)),
            column: context.cursor_column,
            source_x,
            source_y,
            source_width: placed_source_width,
            source_height,
            display_columns,
            display_rows,
            occupied_columns,
            occupied_rows,
            x_offset: command.u32_value('X').unwrap_or(0),
            y_offset: command.u32_value('Y').unwrap_or(0),
            z_index: command.i32_value('z').unwrap_or(0),
        });
        Ok((command.u32_value('C').unwrap_or(0) == 0).then_some((occupied_columns, occupied_rows)))
    }

    fn delete(
        &mut self,
        command: &KittyGraphicsCommand,
        cursor_column: usize,
        cursor_row: usize,
        history_size: usize,
        screen: KittyGraphicsScreen,
    ) -> KittyGraphicsApplyResult {
        self.pending = None;
        let selector = command.char_value('d').unwrap_or('a');
        let free_data = selector.is_ascii_uppercase();
        let selector = selector.to_ascii_lowercase();
        let before = self.placements.len();
        match selector {
            'a' => self
                .placements
                .retain(|placement| placement.screen != screen),
            'i' => {
                let image_id = command.u32_value('i').unwrap_or(0);
                let placement_id = command.u32_value('p').unwrap_or(0);
                self.placements.retain(|placement| {
                    placement.screen != screen
                        || placement.image_id != image_id
                        || (placement_id != 0 && placement.placement_id != placement_id)
                });
                if free_data
                    && !self
                        .placements
                        .iter()
                        .any(|placement| placement.image_id == image_id)
                {
                    self.remove_image(image_id);
                }
            }
            'c' => {
                let line = i64::try_from(history_size)
                    .unwrap_or(i64::MAX)
                    .saturating_add(i64::try_from(cursor_row).unwrap_or(i64::MAX));
                self.placements.retain(|placement| {
                    placement.screen != screen
                        || !placement_contains(placement, line, cursor_column)
                });
            }
            'p' | 'q' => {
                let column = command.u32_value('x').unwrap_or(1).saturating_sub(1) as usize;
                let row = command.u32_value('y').unwrap_or(1).saturating_sub(1) as i64
                    + i64::try_from(history_size).unwrap_or(i64::MAX);
                let z_index = command.i32_value('z');
                self.placements.retain(|placement| {
                    placement.screen != screen
                        || !placement_contains(placement, row, column)
                        || (selector == 'q' && z_index.is_some_and(|z| placement.z_index != z))
                });
            }
            'x' => {
                let column = command.u32_value('x').unwrap_or(1).saturating_sub(1) as usize;
                self.placements.retain(|placement| {
                    placement.screen != screen
                        || column < placement.column
                        || column
                            >= placement
                                .column
                                .saturating_add(placement.occupied_columns as usize)
                });
            }
            'y' => {
                let row = command.u32_value('y').unwrap_or(1).saturating_sub(1) as i64
                    + i64::try_from(history_size).unwrap_or(i64::MAX);
                self.placements.retain(|placement| {
                    placement.screen != screen
                        || row < placement.anchor_line
                        || row
                            >= placement
                                .anchor_line
                                .saturating_add(i64::from(placement.occupied_rows))
                });
            }
            'z' => {
                let z_index = command.i32_value('z').unwrap_or(0);
                self.placements
                    .retain(|placement| placement.screen != screen || placement.z_index != z_index);
            }
            _ => return self.failure(command, "EINVAL:unsupported delete selector"),
        }
        if free_data {
            self.drop_unplaced_images();
        }
        self.success(command, before != self.placements.len(), None, screen)
    }

    fn resolve_transmission_data(
        &self,
        command: &KittyGraphicsCommand,
        decoded: Vec<u8>,
    ) -> Result<Vec<u8>, String> {
        match command.char_value('t').unwrap_or('d') {
            'd' => Ok(decoded),
            // Paths arrive from the PTY guest. Opening them would let the
            // terminal process read (and for `t`, delete) arbitrary host files.
            'f' | 't' => Err("ENOTSUP:file transmission is not supported".into()),
            's' => Err("ENOTSUP:shared-memory transmission is not supported".into()),
            _ => Err("EINVAL:unsupported transmission medium".into()),
        }
    }

    fn allocate_anonymous_id(&mut self) -> u32 {
        if self.next_anonymous_id == 0 {
            self.next_anonymous_id = u32::MAX;
        }
        while self.images.contains_key(&self.next_anonymous_id) {
            self.next_anonymous_id = self.next_anonymous_id.saturating_sub(1).max(1);
        }
        let id = self.next_anonymous_id;
        self.next_anonymous_id = self.next_anonymous_id.saturating_sub(1).max(1);
        id
    }

    fn enforce_quota(&mut self, protected: Option<u32>) -> bool {
        while self.stored_bytes > MAX_IMAGE_BYTES {
            let Some(candidate) = self.insertion_order.pop_front() else {
                break;
            };
            if protected == Some(candidate)
                || self
                    .placements
                    .iter()
                    .any(|placement| placement.image_id == candidate)
            {
                self.insertion_order.push_back(candidate);
                if self.insertion_order.iter().all(|id| {
                    protected == Some(*id)
                        || self
                            .placements
                            .iter()
                            .any(|placement| placement.image_id == *id)
                }) {
                    break;
                }
                continue;
            }
            self.remove_image(candidate);
        }
        self.stored_bytes <= MAX_IMAGE_BYTES
    }

    fn drop_unplaced_images(&mut self) {
        let ids: Vec<u32> = self
            .images
            .keys()
            .copied()
            .filter(|id| {
                !self
                    .placements
                    .iter()
                    .any(|placement| placement.image_id == *id)
            })
            .collect();
        for id in ids {
            self.remove_image(id);
        }
    }

    fn remove_image(&mut self, image_id: u32) {
        if let Some(image) = self.images.remove(&image_id) {
            self.stored_bytes = self.stored_bytes.saturating_sub(image.byte_len);
        }
        self.placements
            .retain(|placement| placement.image_id != image_id);
        self.insertion_order.retain(|id| *id != image_id);
    }

    fn success(
        &self,
        command: &KittyGraphicsCommand,
        changed: bool,
        cursor_advance: Option<(u32, u32)>,
        screen: KittyGraphicsScreen,
    ) -> KittyGraphicsApplyResult {
        KittyGraphicsApplyResult {
            response: response(command, true, "OK"),
            cursor_advance,
            cursor_advance_screen: cursor_advance.map(|_| screen),
            changed,
        }
    }

    fn failure(&self, command: &KittyGraphicsCommand, message: &str) -> KittyGraphicsApplyResult {
        KittyGraphicsApplyResult {
            response: response(command, false, message),
            ..KittyGraphicsApplyResult::default()
        }
    }
}

fn placement_contains(placement: &Placement, line: i64, column: usize) -> bool {
    line >= placement.anchor_line
        && line
            < placement
                .anchor_line
                .saturating_add(i64::from(placement.occupied_rows))
        && column >= placement.column
        && column
            < placement
                .column
                .saturating_add(placement.occupied_columns as usize)
}

fn response(command: &KittyGraphicsCommand, success: bool, message: &str) -> Option<Vec<u8>> {
    let quiet = command.u32_value('q').unwrap_or(0);
    if (success && quiet >= 1) || (!success && quiet >= 2) {
        return None;
    }
    let image_id = command.u32_value('i').or_else(|| command.u32_value('I'))?;
    let mut control = format!("i={image_id}");
    if let Some(placement_id) = command.u32_value('p') {
        control.push_str(&format!(",p={placement_id}"));
    }
    Some(format!("\x1b_G{control};{message}\x1b\\").into_bytes())
}

fn normalize_image(
    command: &KittyGraphicsCommand,
    data: &[u8],
) -> Result<(Vec<u8>, u32, u32), String> {
    match command.u32_value('f').unwrap_or(32) {
        100 => {
            let mut decoder = png::Decoder::new(Cursor::new(data));
            decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
            let mut reader = decoder
                .read_info()
                .map_err(|_| "EINVAL:invalid PNG image".to_owned())?;
            let (width, height) = (reader.info().width, reader.info().height);
            let color = reader.info().color_type;
            validate_dimensions(width, height, 4)?;
            let decoded_len = reader
                .output_buffer_size()
                .filter(|length| *length <= MAX_IMAGE_BYTES)
                .ok_or_else(|| "EFBIG:decoded PNG exceeds storage limit".to_owned())?;
            let mut decoded = vec![0; decoded_len];
            reader
                .next_frame(&mut decoded)
                .and_then(|_| reader.finish())
                .map_err(|_| "EINVAL:invalid PNG image".to_owned())?;
            let rgba = expand_to_rgba(&decoded, color, width, height)?;
            Ok((rgba, width, height))
        }
        format @ (24 | 32) => {
            let width = command.u32_value('s').unwrap_or(0);
            let height = command.u32_value('v').unwrap_or(0);
            let channels = if format == 24 { 3 } else { 4 };
            let expected = validate_dimensions(width, height, channels)?;
            if data.len() != expected {
                return Err("EINVAL:pixel data length does not match dimensions".into());
            }
            let rgba = if channels == 4 {
                data.to_vec()
            } else {
                expand_to_rgba(data, png::ColorType::Rgb, width, height)?
            };
            Ok((rgba, width, height))
        }
        _ => Err("EINVAL:unsupported image format".into()),
    }
}

fn expand_to_rgba(
    decoded: &[u8],
    color: png::ColorType,
    width: u32,
    height: u32,
) -> Result<Vec<u8>, String> {
    let pixels = (width as usize)
        .checked_mul(height as usize)
        .ok_or_else(|| "EFBIG:image dimensions exceed storage limit".to_owned())?;
    match color {
        png::ColorType::Rgba => {
            if decoded.len() != pixels * 4 {
                return Err("EINVAL:pixel data length does not match dimensions".into());
            }
            Ok(decoded.to_vec())
        }
        png::ColorType::Rgb => {
            if decoded.len() != pixels * 3 {
                return Err("EINVAL:pixel data length does not match dimensions".into());
            }
            let mut rgba = Vec::with_capacity(pixels * 4);
            for chunk in decoded.chunks_exact(3) {
                rgba.extend_from_slice(&[chunk[0], chunk[1], chunk[2], 255]);
            }
            Ok(rgba)
        }
        png::ColorType::Grayscale => {
            if decoded.len() != pixels {
                return Err("EINVAL:pixel data length does not match dimensions".into());
            }
            let mut rgba = Vec::with_capacity(pixels * 4);
            for &value in decoded {
                rgba.extend_from_slice(&[value, value, value, 255]);
            }
            Ok(rgba)
        }
        png::ColorType::GrayscaleAlpha => {
            if decoded.len() != pixels * 2 {
                return Err("EINVAL:pixel data length does not match dimensions".into());
            }
            let mut rgba = Vec::with_capacity(pixels * 4);
            for chunk in decoded.chunks_exact(2) {
                rgba.extend_from_slice(&[chunk[0], chunk[0], chunk[0], chunk[1]]);
            }
            Ok(rgba)
        }
        _ => Err("EINVAL:unsupported PNG color type".into()),
    }
}

fn validate_dimensions(width: u32, height: u32, channels: usize) -> Result<usize, String> {
    if width == 0 || height == 0 || width > MAX_DIMENSION || height > MAX_DIMENSION {
        return Err("EINVAL:invalid image dimensions".into());
    }
    let pixels = u64::from(width) * u64::from(height);
    if pixels > MAX_PIXELS {
        return Err("EFBIG:image dimensions exceed storage limit".into());
    }
    usize::try_from(pixels)
        .ok()
        .and_then(|pixels| pixels.checked_mul(channels))
        .ok_or_else(|| "EFBIG:image dimensions overflow".into())
}

fn decompress_zlib(data: &[u8]) -> Result<Vec<u8>, String> {
    let mut output = Vec::new();
    ZlibDecoder::new(data)
        .take(MAX_IMAGE_BYTES as u64 + 1)
        .read_to_end(&mut output)
        .map_err(|_| "EINVAL:invalid zlib payload".to_owned())?;
    if output.len() > MAX_IMAGE_BYTES {
        return Err("EFBIG:decompressed image exceeds storage limit".into());
    }
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn size() -> KittyGraphicsSize {
        KittyGraphicsSize {
            columns: 80,
            rows: 24,
            cell_width: 8.0,
            cell_height: 16.0,
        }
    }

    fn command(control: &str, payload: &[u8]) -> KittyGraphicsCommand {
        let mut bytes = control.as_bytes().to_vec();
        bytes.push(b';');
        bytes.extend_from_slice(BASE64.encode(payload).as_bytes());
        KittyGraphicsCommand::parse(bytes, false)
    }

    #[test]
    fn interceptor_removes_kitty_apc_and_preserves_text() {
        let mut interceptor = KittyGraphicsInterceptor::default();
        let items = interceptor.process(b"before\x1b_Ga=q,i=7;AAAA\x1b\\after");
        assert!(matches!(&items[0], KittyGraphicsItem::Text(text) if text == b"before"));
        assert!(matches!(&items[1], KittyGraphicsItem::Command(_)));
        assert!(matches!(&items[2], KittyGraphicsItem::Text(text) if text == b"after"));
    }

    #[test]
    fn uploads_raw_rgba_and_places_at_cursor() {
        let mut graphics = KittyGraphicsState::default();
        let result = graphics.apply(
            command("a=T,f=32,s=1,v=1,i=7,c=2,r=3", &[1, 2, 3, 255]),
            4,
            5,
            0,
            size(),
            KittyGraphicsScreen::Primary,
        );
        assert!(result.changed);
        assert_eq!(result.cursor_advance, Some((2, 3)));
        let placements = graphics.render_placements(0, 0, 24, 80, KittyGraphicsScreen::Primary);
        assert_eq!(placements.len(), 1);
        assert_eq!(placements[0].column, 4);
        assert_eq!(placements[0].viewport_row, 5);
        assert_eq!(placements[0].rgba.as_ref(), &[1, 2, 3, 255]);
    }

    #[test]
    fn assembles_chunked_upload_before_displaying() {
        let mut graphics = KittyGraphicsState::default();
        let first = graphics.apply(
            command("a=T,f=32,s=1,v=1,i=8,m=1", &[1, 2]),
            0,
            0,
            0,
            size(),
            KittyGraphicsScreen::Primary,
        );
        assert!(!first.changed);
        let second = graphics.apply(
            command("m=0", &[3, 255]),
            0,
            0,
            0,
            size(),
            KittyGraphicsScreen::Primary,
        );
        assert!(second.changed);
        assert_eq!(
            graphics
                .render_placements(0, 0, 24, 80, KittyGraphicsScreen::Primary)
                .len(),
            1
        );
    }

    #[test]
    fn interceptor_does_not_treat_utf8_continuation_as_c1_apc() {
        let mut interceptor = KittyGraphicsInterceptor::default();
        assert!(
            matches!(interceptor.process(b"\xf0").as_slice(), [KittyGraphicsItem::Text(text)] if text == b"\xf0")
        );
        let items = interceptor.process(b"\x9f\x94\x8d Resolving\x1b_Ga=q,i=7;AAAA\x1b\\");
        assert!(
            matches!(&items[0], KittyGraphicsItem::Text(text) if text == b"\x9f\x94\x8d Resolving")
        );
        assert!(matches!(&items[1], KittyGraphicsItem::Command(_)));
    }

    #[test]
    fn refuses_file_transmission_medium() {
        // Valid 1x1 RGBA: a regression that re-opens `t=f` paths would succeed.
        let path = std::env::temp_dir().join(format!(
            "kero-kitty-graphics-file-medium-{}.rgba",
            std::process::id()
        ));
        std::fs::write(&path, [1, 2, 3, 255]).expect("write a readable probe file");
        let payload = path.to_string_lossy().into_owned();
        let mut graphics = KittyGraphicsState::default();
        let result = graphics.apply(
            command("a=T,f=32,s=1,v=1,i=9,t=f", payload.as_bytes()),
            0,
            0,
            0,
            size(),
            KittyGraphicsScreen::Primary,
        );
        let unread = std::fs::read(&path).expect("probe file must remain present");
        let _ = std::fs::remove_file(&path);
        assert_eq!(unread, [1, 2, 3, 255]);
        assert!(!result.changed);
        assert_eq!(
            result.response.as_deref(),
            Some(b"\x1b_Gi=9;ENOTSUP:file transmission is not supported\x1b\\".as_slice())
        );
        assert!(graphics
            .render_placements(0, 0, 24, 80, KittyGraphicsScreen::Primary)
            .is_empty());
    }

    #[test]
    fn refuses_temporary_file_transmission_medium() {
        // Same readable probe as `t=f`; `t=t` must not open or delete it.
        let path = std::env::temp_dir().join(format!(
            "kero-kitty-graphics-temp-medium-{}.rgba",
            std::process::id()
        ));
        std::fs::write(&path, [1, 2, 3, 255]).expect("write a readable probe file");
        let payload = path.to_string_lossy().into_owned();
        let mut graphics = KittyGraphicsState::default();
        let result = graphics.apply(
            command("a=T,f=32,s=1,v=1,i=10,t=t", payload.as_bytes()),
            0,
            0,
            0,
            size(),
            KittyGraphicsScreen::Primary,
        );
        let unread = std::fs::read(&path).expect("probe file must remain present");
        let _ = std::fs::remove_file(&path);
        assert_eq!(unread, [1, 2, 3, 255]);
        assert!(!result.changed);
        assert_eq!(
            result.response.as_deref(),
            Some(b"\x1b_Gi=10;ENOTSUP:file transmission is not supported\x1b\\".as_slice())
        );
        assert!(graphics
            .render_placements(0, 0, 24, 80, KittyGraphicsScreen::Primary)
            .is_empty());
    }

    #[test]
    fn uploads_direct_transmission_medium() {
        let mut graphics = KittyGraphicsState::default();
        let result = graphics.apply(
            command("a=T,f=32,s=1,v=1,i=11,t=d,c=1,r=1", &[1, 2, 3, 255]),
            0,
            0,
            0,
            size(),
            KittyGraphicsScreen::Primary,
        );
        assert!(result.changed);
        assert_eq!(
            graphics
                .render_placements(0, 0, 24, 80, KittyGraphicsScreen::Primary)
                .len(),
            1
        );
    }
}
