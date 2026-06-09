#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TerminalColor {
    Ansi(u8),
    Rgb(u8, u8, u8),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TerminalCell {
    pub ch: char,
    pub bold: bool,
    pub foreground: Option<TerminalColor>,
    pub background: Option<TerminalColor>,
}

impl Default for TerminalCell {
    fn default() -> Self {
        Self {
            ch: ' ',
            bold: false,
            foreground: None,
            background: None,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TerminalSearchOptions {
    pub case_sensitive: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TerminalSearchMatch {
    pub line_index: usize,
    pub start_column: usize,
    pub end_column: usize,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub struct TerminalTextPoint {
    pub line_index: usize,
    pub column: usize,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TerminalTextRange {
    pub start: TerminalTextPoint,
    pub end: TerminalTextPoint,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[derive(Default)]
pub enum TerminalMouseMode {
    #[default]
    Disabled,
    Normal,
    ButtonEvent,
    AnyEvent,
}


#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TerminalProgressState {
    Remove,
    Set,
    Error,
    Indeterminate,
    Pause,
}

impl TerminalProgressState {
    pub fn indicates_activity(self) -> bool {
        !matches!(self, Self::Remove)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TerminalProgressReport {
    pub state: TerminalProgressState,
    pub progress: Option<u8>,
}

impl TerminalProgressReport {
    pub fn indicates_activity(self) -> bool {
        self.state.indicates_activity()
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct TerminalStyle {
    bold: bool,
    foreground: Option<TerminalColor>,
    background: Option<TerminalColor>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct TerminalBufferSnapshot {
    cells: Vec<TerminalCell>,
    cursor_row: usize,
    cursor_col: usize,
    saved_cursor: Option<(usize, usize)>,
    scroll_top: usize,
    scroll_bottom: usize,
    origin_mode_enabled: bool,
}

const PRIMARY_DEVICE_ATTRIBUTES_RESPONSE: &[u8] = b"\x1b[?1;2c";

pub struct TerminalScreen {
    width: usize,
    height: usize,
    scrollback_limit: usize,
    scrollback: Vec<Vec<TerminalCell>>,
    cursor_row: usize,
    cursor_col: usize,
    saved_cursor: Option<(usize, usize)>,
    scroll_top: usize,
    scroll_bottom: usize,
    origin_mode_enabled: bool,
    primary_screen: Option<TerminalBufferSnapshot>,
    cells: Vec<TerminalCell>,
    style: TerminalStyle,
    parser: vte::Parser,
    title: Option<String>,
    progress_report: Option<TerminalProgressReport>,
    bracketed_paste_enabled: bool,
    application_cursor_keys_enabled: bool,
    cursor_visible: bool,
    mouse_mode: TerminalMouseMode,
    sgr_mouse_enabled: bool,
    pending_responses: Vec<u8>,
    /// Rows scrolled up into scrollback for viewing history. 0 = live bottom.
    view_scroll: usize,
    /// A BEL (0x07) was received since the last [`take_bell`](Self::take_bell).
    bell_pending: bool,
}

impl TerminalScreen {
    pub const DEFAULT_SCROLLBACK_LIMIT: usize = 10_000;

    pub fn new(width: usize, height: usize) -> Self {
        Self::with_scrollback_limit(width, height, Self::DEFAULT_SCROLLBACK_LIMIT)
    }

    pub fn with_scrollback_limit(width: usize, height: usize, scrollback_limit: usize) -> Self {
        let width = width.max(1);
        let height = height.max(1);
        Self {
            width,
            height,
            scrollback_limit,
            scrollback: Vec::new(),
            cursor_row: 0,
            cursor_col: 0,
            saved_cursor: None,
            scroll_top: 0,
            scroll_bottom: height - 1,
            origin_mode_enabled: false,
            primary_screen: None,
            cells: vec![TerminalCell::default(); width * height],
            style: TerminalStyle::default(),
            parser: vte::Parser::new(),
            title: None,
            progress_report: None,
            bracketed_paste_enabled: false,
            application_cursor_keys_enabled: false,
            cursor_visible: true,
            mouse_mode: TerminalMouseMode::Disabled,
            sgr_mouse_enabled: false,
            pending_responses: Vec::new(),
            view_scroll: 0,
            bell_pending: false,
        }
    }

    pub fn feed(&mut self, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        // New output snaps the viewport back to the live bottom.
        self.view_scroll = 0;
        let mut parser = std::mem::replace(&mut self.parser, vte::Parser::new());
        parser.advance(self, bytes);
        self.parser = parser;
    }

    pub fn resize(&mut self, width: usize, height: usize) {
        let width = width.max(1);
        let height = height.max(1);
        if self.width == width && self.height == height {
            return;
        }
        self.view_scroll = 0;

        let old_width = self.width;
        let old_height = self.height;
        self.cells = resize_cells(&self.cells, old_width, old_height, width, height);
        if let Some(primary) = &mut self.primary_screen {
            primary.cells = resize_cells(&primary.cells, old_width, old_height, width, height);
            primary.cursor_row = primary.cursor_row.min(height - 1);
            primary.cursor_col = primary.cursor_col.min(width - 1);
            primary.saved_cursor = clamp_saved_cursor(primary.saved_cursor, width, height);
            (primary.scroll_top, primary.scroll_bottom) =
                clamp_scroll_region(primary.scroll_top, primary.scroll_bottom, height);
            if primary.origin_mode_enabled {
                primary.cursor_row = primary.cursor_row.max(primary.scroll_top);
            }
        }
        self.width = width;
        self.height = height;
        self.cursor_row = self.cursor_row.min(height - 1);
        self.cursor_col = self.cursor_col.min(width - 1);
        self.saved_cursor = clamp_saved_cursor(self.saved_cursor, width, height);
        (self.scroll_top, self.scroll_bottom) =
            clamp_scroll_region(self.scroll_top, self.scroll_bottom, height);
        if self.origin_mode_enabled {
            self.cursor_row = self.cursor_row.clamp(self.scroll_top, self.scroll_bottom);
        }
    }

    pub fn visible_lines(&self) -> Vec<String> {
        (0..self.height).map(|row| self.line_string(row)).collect()
    }

    pub fn scrollback_lines(&self) -> Vec<String> {
        if self.primary_screen.is_some() {
            return Vec::new();
        }

        self.scrollback
            .iter()
            .map(|line| line.iter().map(|cell| cell.ch).collect())
            .collect()
    }

    pub fn all_lines(&self) -> Vec<String> {
        let mut lines = self.scrollback_lines();
        lines.extend(self.visible_lines());
        lines
    }

    pub fn search(&self, needle: &str, options: TerminalSearchOptions) -> Vec<TerminalSearchMatch> {
        if needle.is_empty() {
            return Vec::new();
        }

        let needle_chars: Vec<char> = needle.chars().collect();
        let needle_len = needle_chars.len();
        self.all_lines()
            .iter()
            .enumerate()
            .flat_map(|(line_index, line)| {
                find_matches_in_line(line, &needle_chars, options.case_sensitive)
                    .into_iter()
                    .map(move |start_column| TerminalSearchMatch {
                        line_index,
                        start_column,
                        end_column: start_column + needle_len,
                    })
            })
            .collect()
    }

    pub fn plain_text(&self) -> String {
        let mut lines: Vec<String> = self
            .all_lines()
            .into_iter()
            .map(|line| trim_terminal_padding(&line).to_string())
            .collect();
        while lines.last().is_some_and(|line| line.is_empty()) {
            lines.pop();
        }
        lines.join("\n")
    }

    pub fn title(&self) -> Option<&str> {
        self.title.as_deref()
    }

    pub fn progress_report(&self) -> Option<TerminalProgressReport> {
        self.progress_report
    }

    pub fn terminal_progress_indicates_activity(&self) -> bool {
        self.progress_report
            .is_some_and(TerminalProgressReport::indicates_activity)
    }

    pub fn bracketed_paste_enabled(&self) -> bool {
        self.bracketed_paste_enabled
    }

    pub fn application_cursor_keys_enabled(&self) -> bool {
        self.application_cursor_keys_enabled
    }

    pub fn cursor_visible(&self) -> bool {
        self.cursor_visible
    }

    pub fn mouse_mode(&self) -> TerminalMouseMode {
        self.mouse_mode
    }

    pub fn sgr_mouse_enabled(&self) -> bool {
        self.sgr_mouse_enabled
    }

    pub fn take_pending_responses(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.pending_responses)
    }

    pub fn text_in_range(&self, range: TerminalTextRange) -> Option<String> {
        let (start, end) = if range.start <= range.end {
            (range.start, range.end)
        } else {
            (range.end, range.start)
        };
        let lines = self.all_lines();
        if start.line_index >= lines.len() || end.line_index >= lines.len() {
            return None;
        }

        let mut selected = Vec::new();
        for (line_index, line) in lines
            .iter()
            .enumerate()
            .take(end.line_index + 1)
            .skip(start.line_index)
        {
            let line_width = line.chars().count();
            let start_column = if line_index == start.line_index {
                start.column
            } else {
                0
            };
            let end_column = if line_index == end.line_index {
                end.column
            } else {
                line_width
            };
            if start_column > line_width || end_column > line_width || start_column > end_column {
                return None;
            }

            let segment = slice_columns(line, start_column, end_column);
            selected.push(trim_terminal_padding(&segment).to_string());
        }
        Some(selected.join("\n"))
    }

    pub fn cursor_position(&self) -> (usize, usize) {
        (self.cursor_row, self.cursor_col)
    }

    /// Visible grid width in columns.
    pub fn width(&self) -> usize {
        self.width
    }

    /// Visible grid height in rows.
    pub fn height(&self) -> usize {
        self.height
    }

    pub fn cell(&self, row: usize, column: usize) -> Option<&TerminalCell> {
        (row < self.height && column < self.width).then(|| &self.cells[self.index(row, column)])
    }

    /// Number of full lines currently held in scrollback (cheap; empty on the
    /// alternate screen, matching [`scrollback_lines`](Self::scrollback_lines)).
    pub fn scrollback_len(&self) -> usize {
        if self.primary_screen.is_some() {
            0
        } else {
            self.scrollback.len()
        }
    }

    /// Current viewport scroll-back offset in rows (0 = live bottom).
    pub fn view_scroll(&self) -> usize {
        self.view_scroll
    }

    /// Take and clear the pending-bell flag (set when a BEL/0x07 was received).
    pub fn take_bell(&mut self) -> bool {
        std::mem::take(&mut self.bell_pending)
    }

    /// Scroll the viewport up into history by `rows` (clamped to scrollback).
    pub fn scroll_view_up(&mut self, rows: usize) {
        self.view_scroll = (self.view_scroll + rows).min(self.scrollback_len());
    }

    /// Scroll the viewport down toward the live bottom by `rows`.
    pub fn scroll_view_down(&mut self, rows: usize) {
        self.view_scroll = self.view_scroll.saturating_sub(rows);
    }

    /// Reset the viewport to the live bottom.
    pub fn reset_view_scroll(&mut self) {
        self.view_scroll = 0;
    }

    /// The cell at viewport `(row, column)` accounting for [`view_scroll`]: when
    /// scrolled, the top rows show scrollback history. Returns the owned cell
    /// (or `None` past the buffer / a short scrollback line).
    ///
    /// [`view_scroll`]: Self::view_scroll
    pub fn view_cell(&self, row: usize, column: usize) -> Option<TerminalCell> {
        if column >= self.width || row >= self.height {
            return None;
        }
        let scrollback_len = self.scrollback_len();
        // Absolute combined-buffer row of viewport row 0 (scrollback first,
        // then the live grid). Matches `terminal_point_for_render_cell`.
        let top = scrollback_len - self.view_scroll.min(scrollback_len);
        let absolute = top + row;
        if absolute < scrollback_len {
            self.scrollback[absolute].get(column).copied()
        } else {
            self.cell(absolute - scrollback_len, column).copied()
        }
    }

    fn print_char(&mut self, ch: char) {
        if self.cursor_row >= self.height {
            self.scroll_up();
        }
        let index = self.index(self.cursor_row, self.cursor_col);
        self.cells[index] = TerminalCell {
            ch,
            bold: self.style.bold,
            foreground: self.style.foreground,
            background: self.style.background,
        };
        self.advance_cursor();
    }

    fn advance_cursor(&mut self) {
        self.cursor_col += 1;
        if self.cursor_col >= self.width {
            self.cursor_col = 0;
            self.line_feed();
        }
    }

    fn line_feed(&mut self) {
        if self.cursor_row == self.scroll_bottom {
            self.scroll_up();
        } else if self.cursor_row + 1 < self.height {
            self.cursor_row += 1;
        }
    }

    fn scroll_up(&mut self) {
        if self.scroll_top == 0 && self.scroll_bottom == self.height - 1 {
            self.capture_scrollback_line(0);
        }
        self.scroll_region_up(self.scroll_top, self.scroll_bottom, 1);
        self.cursor_row = self.scroll_bottom;
    }

    fn scroll_region_up(&mut self, top: usize, bottom: usize, count: usize) {
        let row_count = bottom.saturating_sub(top) + 1;
        let count = count.min(row_count);
        if count == 0 {
            return;
        }
        if count >= row_count {
            for row in top..=bottom {
                self.clear_row(row);
            }
            return;
        }

        for row in top..=(bottom - count) {
            self.copy_row(row + count, row);
        }
        for row in (bottom - count + 1)..=bottom {
            self.clear_row(row);
        }
    }

    fn scroll_region_down(&mut self, top: usize, bottom: usize, count: usize) {
        let row_count = bottom.saturating_sub(top) + 1;
        let count = count.min(row_count);
        if count == 0 {
            return;
        }
        if count >= row_count {
            for row in top..=bottom {
                self.clear_row(row);
            }
            return;
        }

        for row in ((top + count)..=bottom).rev() {
            self.copy_row(row - count, row);
        }
        for row in top..(top + count) {
            self.clear_row(row);
        }
    }

    fn set_vertical_margins(&mut self, params: &vte::Params) {
        let top = param_at(params, 0).unwrap_or(1).saturating_sub(1);
        let bottom = param_at(params, 1).unwrap_or(self.height).saturating_sub(1);

        if top < bottom && bottom < self.height {
            self.scroll_top = top;
            self.scroll_bottom = bottom;
        } else {
            self.scroll_top = 0;
            self.scroll_bottom = self.height - 1;
        }
        self.cursor_home();
    }

    fn cursor_next_line(&mut self, count: usize) {
        self.cursor_row = (self.cursor_row + count).min(self.height - 1);
        self.cursor_col = 0;
    }

    fn cursor_previous_line(&mut self, count: usize) {
        self.cursor_row = self.cursor_row.saturating_sub(count);
        self.cursor_col = 0;
    }

    fn next_line(&mut self) {
        self.cursor_col = 0;
        self.line_feed();
    }

    fn reverse_index(&mut self) {
        if self.cursor_row == self.scroll_top {
            self.scroll_region_down(self.scroll_top, self.scroll_bottom, 1);
        } else if self.cursor_row > 0 {
            self.cursor_row -= 1;
        }
    }

    fn horizontal_tab(&mut self) {
        let next_tab_stop = ((self.cursor_col / 8) + 1) * 8;
        self.cursor_col = next_tab_stop.min(self.width - 1);
    }

    fn capture_scrollback_line(&mut self, row: usize) {
        if self.primary_screen.is_some() || self.scrollback_limit == 0 {
            return;
        }
        let line = (0..self.width)
            .map(|column| self.cells[self.index(row, column)])
            .collect();
        self.scrollback.push(line);
        let overflow = self.scrollback.len().saturating_sub(self.scrollback_limit);
        if overflow > 0 {
            self.scrollback.drain(0..overflow);
        }
    }

    fn clear_screen(&mut self) {
        self.cells.fill(TerminalCell::default());
        self.cursor_row = 0;
        self.cursor_col = 0;
    }

    fn clear_line_from_cursor(&mut self) {
        self.clear_line_range(self.cursor_row, self.cursor_col, self.width);
    }

    fn clear_line_to_cursor(&mut self) {
        self.clear_line_range(self.cursor_row, 0, self.cursor_col + 1);
    }

    fn clear_entire_line(&mut self) {
        self.clear_line_range(self.cursor_row, 0, self.width);
    }

    fn clear_display_from_cursor(&mut self) {
        self.clear_line_from_cursor();
        for row in (self.cursor_row + 1)..self.height {
            self.clear_row(row);
        }
    }

    fn clear_display_to_cursor(&mut self) {
        for row in 0..self.cursor_row {
            self.clear_row(row);
        }
        self.clear_line_to_cursor();
    }

    fn clear_line_range(&mut self, row: usize, start_column: usize, end_column: usize) {
        let end_column = end_column.min(self.width);
        for column in start_column.min(self.width)..end_column {
            let index = self.index(row, column);
            self.cells[index] = TerminalCell::default();
        }
    }

    fn insert_blank_chars(&mut self, count: usize) {
        let available = self.width.saturating_sub(self.cursor_col);
        let count = count.min(available);
        if count == 0 {
            return;
        }

        for column in (self.cursor_col + count..self.width).rev() {
            let source = self.index(self.cursor_row, column - count);
            let destination = self.index(self.cursor_row, column);
            self.cells[destination] = self.cells[source];
        }
        self.clear_line_range(self.cursor_row, self.cursor_col, self.cursor_col + count);
    }

    fn delete_chars(&mut self, count: usize) {
        let available = self.width.saturating_sub(self.cursor_col);
        let count = count.min(available);
        if count == 0 {
            return;
        }

        for column in self.cursor_col..(self.width - count) {
            let source = self.index(self.cursor_row, column + count);
            let destination = self.index(self.cursor_row, column);
            self.cells[destination] = self.cells[source];
        }
        self.clear_line_range(self.cursor_row, self.width - count, self.width);
    }

    fn scroll_visible_up(&mut self, count: usize) {
        let count = count.min(self.height);
        if count == 0 {
            return;
        }

        for row in 0..(self.height - count) {
            self.copy_row(row + count, row);
        }
        for row in (self.height - count)..self.height {
            self.clear_row(row);
        }
    }

    fn scroll_visible_down(&mut self, count: usize) {
        let count = count.min(self.height);
        if count == 0 {
            return;
        }

        for row in (count..self.height).rev() {
            self.copy_row(row - count, row);
        }
        for row in 0..count {
            self.clear_row(row);
        }
    }

    fn erase_chars(&mut self, count: usize) {
        let available = self.width.saturating_sub(self.cursor_col);
        let count = count.min(available);
        if count == 0 {
            return;
        }

        self.clear_line_range(self.cursor_row, self.cursor_col, self.cursor_col + count);
    }

    fn insert_blank_lines(&mut self, count: usize) {
        if !self.cursor_inside_scroll_region() {
            return;
        }

        let available = self.scroll_bottom + 1 - self.cursor_row;
        let count = count.min(available);
        if count == 0 {
            return;
        }
        if count >= available {
            for row in self.cursor_row..=self.scroll_bottom {
                self.clear_row(row);
            }
            return;
        }

        for row in (self.cursor_row + count..=self.scroll_bottom).rev() {
            self.copy_row(row - count, row);
        }
        for row in self.cursor_row..(self.cursor_row + count) {
            self.clear_row(row);
        }
    }

    fn delete_lines(&mut self, count: usize) {
        if !self.cursor_inside_scroll_region() {
            return;
        }

        let available = self.scroll_bottom + 1 - self.cursor_row;
        let count = count.min(available);
        if count == 0 {
            return;
        }
        if count >= available {
            for row in self.cursor_row..=self.scroll_bottom {
                self.clear_row(row);
            }
            return;
        }

        for row in self.cursor_row..=(self.scroll_bottom - count) {
            self.copy_row(row + count, row);
        }
        for row in (self.scroll_bottom - count + 1)..=self.scroll_bottom {
            self.clear_row(row);
        }
    }

    fn cursor_inside_scroll_region(&self) -> bool {
        self.cursor_row >= self.scroll_top && self.cursor_row <= self.scroll_bottom
    }

    fn copy_row(&mut self, from_row: usize, to_row: usize) {
        for column in 0..self.width {
            let from = self.index(from_row, column);
            let to = self.index(to_row, column);
            self.cells[to] = self.cells[from];
        }
    }

    fn clear_row(&mut self, row: usize) {
        for column in 0..self.width {
            let index = self.index(row, column);
            self.cells[index] = TerminalCell::default();
        }
    }

    fn set_cursor_position(&mut self, row: usize, column: usize) {
        self.cursor_row = row.min(self.height - 1);
        self.cursor_col = column.min(self.width - 1);
    }

    fn set_csi_cursor_position(&mut self, row: usize, column: usize) {
        if self.origin_mode_enabled {
            self.cursor_row = (self.scroll_top + row).min(self.scroll_bottom);
        } else {
            self.cursor_row = row.min(self.height - 1);
        }
        self.cursor_col = column.min(self.width - 1);
    }

    fn cursor_home(&mut self) {
        if self.origin_mode_enabled {
            self.set_cursor_position(self.scroll_top, 0);
        } else {
            self.set_cursor_position(0, 0);
        }
    }

    fn save_cursor(&mut self) {
        self.saved_cursor = Some((self.cursor_row, self.cursor_col));
    }

    fn restore_cursor(&mut self) {
        if let Some((row, column)) = self.saved_cursor {
            self.set_cursor_position(row, column);
        }
    }

    fn enter_alternate_screen(&mut self) {
        if self.primary_screen.is_some() {
            return;
        }

        self.primary_screen = Some(TerminalBufferSnapshot {
            cells: self.cells.clone(),
            cursor_row: self.cursor_row,
            cursor_col: self.cursor_col,
            saved_cursor: self.saved_cursor,
            scroll_top: self.scroll_top,
            scroll_bottom: self.scroll_bottom,
            origin_mode_enabled: self.origin_mode_enabled,
        });
        self.cells = vec![TerminalCell::default(); self.width * self.height];
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.saved_cursor = None;
        self.scroll_top = 0;
        self.scroll_bottom = self.height - 1;
        self.origin_mode_enabled = false;
    }

    fn leave_alternate_screen(&mut self) {
        let Some(primary) = self.primary_screen.take() else {
            return;
        };

        self.cells = primary.cells;
        self.cursor_row = primary.cursor_row.min(self.height - 1);
        self.cursor_col = primary.cursor_col.min(self.width - 1);
        self.saved_cursor = clamp_saved_cursor(primary.saved_cursor, self.width, self.height);
        (self.scroll_top, self.scroll_bottom) =
            clamp_scroll_region(primary.scroll_top, primary.scroll_bottom, self.height);
        self.origin_mode_enabled = primary.origin_mode_enabled;
        if self.origin_mode_enabled {
            self.cursor_row = self.cursor_row.clamp(self.scroll_top, self.scroll_bottom);
        }
    }

    fn apply_private_mode(&mut self, params: &vte::Params, enabled: bool) {
        for value in params_to_values(params) {
            match value {
                1 => self.application_cursor_keys_enabled = enabled,
                6 => {
                    self.origin_mode_enabled = enabled;
                    self.cursor_home();
                }
                25 => self.cursor_visible = enabled,
                1000 => {
                    if enabled {
                        self.mouse_mode = TerminalMouseMode::Normal;
                    } else if self.mouse_mode == TerminalMouseMode::Normal {
                        self.mouse_mode = TerminalMouseMode::Disabled;
                    }
                }
                1002 => {
                    if enabled {
                        self.mouse_mode = TerminalMouseMode::ButtonEvent;
                    } else if self.mouse_mode == TerminalMouseMode::ButtonEvent {
                        self.mouse_mode = TerminalMouseMode::Disabled;
                    }
                }
                1003 => {
                    if enabled {
                        self.mouse_mode = TerminalMouseMode::AnyEvent;
                    } else if self.mouse_mode == TerminalMouseMode::AnyEvent {
                        self.mouse_mode = TerminalMouseMode::Disabled;
                    }
                }
                1006 => self.sgr_mouse_enabled = enabled,
                1049 => {
                    if enabled {
                        self.enter_alternate_screen();
                    } else {
                        self.leave_alternate_screen();
                    }
                }
                2004 => self.bracketed_paste_enabled = enabled,
                _ => {}
            }
        }
    }

    fn report_device_status(&mut self, params: &vte::Params) {
        match first_param(params).unwrap_or(0) {
            5 => self.pending_responses.extend_from_slice(b"\x1b[0n"),
            6 => {
                let response = format!("\x1b[{};{}R", self.cursor_row + 1, self.cursor_col + 1);
                self.pending_responses
                    .extend_from_slice(response.as_bytes());
            }
            _ => {}
        }
    }

    fn report_primary_device_attributes(&mut self, params: &vte::Params, intermediates: &[u8]) {
        if !intermediates.is_empty() || first_param(params).unwrap_or(0) != 0 {
            return;
        }

        self.pending_responses
            .extend_from_slice(PRIMARY_DEVICE_ATTRIBUTES_RESPONSE);
    }

    fn hard_reset(&mut self) {
        self.scrollback.clear();
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.saved_cursor = None;
        self.primary_screen = None;
        self.cells = vec![TerminalCell::default(); self.width * self.height];
        self.style = TerminalStyle::default();
        self.scroll_top = 0;
        self.scroll_bottom = self.height - 1;
        self.origin_mode_enabled = false;
        self.bracketed_paste_enabled = false;
        self.application_cursor_keys_enabled = false;
        self.cursor_visible = true;
        self.mouse_mode = TerminalMouseMode::Disabled;
        self.sgr_mouse_enabled = false;
        self.progress_report = None;
    }

    fn index(&self, row: usize, column: usize) -> usize {
        row * self.width + column
    }

    fn line_string(&self, row: usize) -> String {
        (0..self.width)
            .map(|column| self.cells[self.index(row, column)].ch)
            .collect()
    }
}

impl vte::Perform for TerminalScreen {
    fn print(&mut self, c: char) {
        self.print_char(c);
    }

    fn execute(&mut self, byte: u8) {
        match byte {
            0x07 => self.bell_pending = true,
            b'\r' => self.cursor_col = 0,
            b'\n' => self.line_feed(),
            0x08 => self.cursor_col = self.cursor_col.saturating_sub(1),
            b'\t' => self.horizontal_tab(),
            _ => {}
        }
    }

    fn hook(&mut self, _params: &vte::Params, _intermediates: &[u8], _ignore: bool, _action: char) {
    }

    fn put(&mut self, _byte: u8) {}

    fn unhook(&mut self) {}

    fn osc_dispatch(&mut self, params: &[&[u8]], _bell_terminated: bool) {
        if let Some(title) = osc_title(params) {
            self.title = Some(title);
        }
        if let Some(report) = osc_progress_report(params) {
            self.progress_report = Some(report);
        }
    }

    fn csi_dispatch(
        &mut self,
        params: &vte::Params,
        intermediates: &[u8],
        _ignore: bool,
        action: char,
    ) {
        match action {
            '@' => {
                let count = first_param(params).unwrap_or(1);
                self.insert_blank_chars(count);
            }
            'A' => {
                let count = first_param(params).unwrap_or(1);
                self.cursor_row = self.cursor_row.saturating_sub(count);
            }
            'B' => {
                let count = first_param(params).unwrap_or(1);
                self.cursor_row = (self.cursor_row + count).min(self.height - 1);
            }
            'C' => {
                let count = first_param(params).unwrap_or(1);
                self.cursor_col = (self.cursor_col + count).min(self.width - 1);
            }
            'D' => {
                let count = first_param(params).unwrap_or(1);
                self.cursor_col = self.cursor_col.saturating_sub(count);
            }
            'E' => {
                let count = first_param(params).unwrap_or(1);
                self.cursor_next_line(count);
            }
            'F' => {
                let count = first_param(params).unwrap_or(1);
                self.cursor_previous_line(count);
            }
            'G' => {
                let column = first_param(params).unwrap_or(1).saturating_sub(1);
                self.cursor_col = column.min(self.width - 1);
            }
            'H' | 'f' => {
                let row = param_at(params, 0).unwrap_or(1).saturating_sub(1);
                let column = param_at(params, 1).unwrap_or(1).saturating_sub(1);
                self.set_csi_cursor_position(row, column);
            }
            'J' => match first_param(params).unwrap_or(0) {
                0 => self.clear_display_from_cursor(),
                1 => self.clear_display_to_cursor(),
                2 => self.clear_screen(),
                3 => self.scrollback.clear(),
                _ => {}
            },
            'K' => match first_param(params).unwrap_or(0) {
                0 => self.clear_line_from_cursor(),
                1 => self.clear_line_to_cursor(),
                2 => self.clear_entire_line(),
                _ => {}
            },
            'L' => {
                let count = first_param(params).unwrap_or(1);
                self.insert_blank_lines(count);
            }
            'M' => {
                let count = first_param(params).unwrap_or(1);
                self.delete_lines(count);
            }
            'P' => {
                let count = first_param(params).unwrap_or(1);
                self.delete_chars(count);
            }
            'S' => {
                let count = first_param(params).unwrap_or(1);
                self.scroll_visible_up(count);
            }
            'T' => {
                let count = first_param(params).unwrap_or(1);
                self.scroll_visible_down(count);
            }
            'X' => {
                let count = first_param(params).unwrap_or(1);
                self.erase_chars(count);
            }
            'c' => self.report_primary_device_attributes(params, intermediates),
            'd' => {
                let row = first_param(params).unwrap_or(1).saturating_sub(1);
                self.set_csi_cursor_position(row, self.cursor_col);
            }
            'h' | 'l' if is_private_csi(intermediates) => {
                self.apply_private_mode(params, action == 'h');
            }
            'm' => self.apply_sgr(params),
            'n' => self.report_device_status(params),
            'r' if intermediates.is_empty() => self.set_vertical_margins(params),
            's' => self.save_cursor(),
            'u' => self.restore_cursor(),
            _ => {}
        }
    }

    fn esc_dispatch(&mut self, _intermediates: &[u8], _ignore: bool, byte: u8) {
        match byte {
            b'D' => self.line_feed(),
            b'E' => self.next_line(),
            b'M' => self.reverse_index(),
            b'7' => self.save_cursor(),
            b'8' => self.restore_cursor(),
            b'c' => self.hard_reset(),
            _ => {}
        }
    }
}

impl TerminalScreen {
    fn apply_sgr(&mut self, params: &vte::Params) {
        let values: Vec<usize> = params_to_values(params);
        let values = if values.is_empty() { vec![0] } else { values };
        let mut index = 0;
        while index < values.len() {
            match values[index] {
                0 => self.style = TerminalStyle::default(),
                1 => self.style.bold = true,
                22 => self.style.bold = false,
                30..=37 => {
                    self.style.foreground = Some(TerminalColor::Ansi((values[index] - 30) as u8));
                }
                39 => self.style.foreground = None,
                40..=47 => {
                    self.style.background = Some(TerminalColor::Ansi((values[index] - 40) as u8));
                }
                49 => self.style.background = None,
                90..=97 => {
                    self.style.foreground =
                        Some(TerminalColor::Ansi((values[index] - 90 + 8) as u8));
                }
                100..=107 => {
                    self.style.background =
                        Some(TerminalColor::Ansi((values[index] - 100 + 8) as u8));
                }
                38 | 48 => {
                    if let Some((color, consumed)) = parse_extended_color(&values[index + 1..]) {
                        if values[index] == 38 {
                            self.style.foreground = Some(color);
                        } else {
                            self.style.background = Some(color);
                        }
                        index += consumed + 1;
                        continue;
                    }
                }
                _ => {}
            }
            index += 1;
        }
    }
}

fn first_param(params: &vte::Params) -> Option<usize> {
    param_at(params, 0)
}

fn param_at(params: &vte::Params, index: usize) -> Option<usize> {
    params
        .iter()
        .nth(index)
        .and_then(|values| values.first())
        .map(|value| usize::from(*value))
        .filter(|value| *value != 0)
}

fn params_to_values(params: &vte::Params) -> Vec<usize> {
    params
        .iter()
        .flat_map(|values| values.iter())
        .map(|value| usize::from(*value))
        .collect()
}

fn is_private_csi(intermediates: &[u8]) -> bool {
    intermediates == b"?"
}

fn resize_cells(
    old_cells: &[TerminalCell],
    old_width: usize,
    old_height: usize,
    width: usize,
    height: usize,
) -> Vec<TerminalCell> {
    let mut cells = vec![TerminalCell::default(); width * height];
    let copy_width = old_width.min(width);
    let copy_height = old_height.min(height);
    for row in 0..copy_height {
        for column in 0..copy_width {
            cells[row * width + column] = old_cells[row * old_width + column];
        }
    }
    cells
}

fn clamp_saved_cursor(
    saved_cursor: Option<(usize, usize)>,
    width: usize,
    height: usize,
) -> Option<(usize, usize)> {
    saved_cursor.map(|(row, column)| (row.min(height - 1), column.min(width - 1)))
}

fn clamp_scroll_region(top: usize, bottom: usize, height: usize) -> (usize, usize) {
    let top = top.min(height - 1);
    let bottom = bottom.min(height - 1);
    if top < bottom {
        (top, bottom)
    } else {
        (0, height - 1)
    }
}

fn parse_extended_color(values: &[usize]) -> Option<(TerminalColor, usize)> {
    match values.first().copied()? {
        5 => values
            .get(1)
            .map(|color| (TerminalColor::Ansi((*color).min(255) as u8), 2)),
        2 => {
            let red = *values.get(1)?;
            let green = *values.get(2)?;
            let blue = *values.get(3)?;
            Some((
                TerminalColor::Rgb(
                    red.min(255) as u8,
                    green.min(255) as u8,
                    blue.min(255) as u8,
                ),
                4,
            ))
        }
        _ => None,
    }
}

fn osc_title(params: &[&[u8]]) -> Option<String> {
    let command = params.first()?;
    if !matches!(*command, b"0" | b"1" | b"2") {
        return None;
    }

    let mut title = Vec::new();
    for (index, part) in params.iter().skip(1).enumerate() {
        if index > 0 {
            title.push(b';');
        }
        title.extend_from_slice(part);
    }
    Some(String::from_utf8_lossy(&title).into_owned())
}

fn osc_progress_report(params: &[&[u8]]) -> Option<TerminalProgressReport> {
    if params.first()? != b"9" || params.get(1)? != b"4" {
        return None;
    }

    let state = match parse_ascii_u8(params.get(2)?)? {
        0 => TerminalProgressState::Remove,
        1 => TerminalProgressState::Set,
        2 => TerminalProgressState::Error,
        3 => TerminalProgressState::Indeterminate,
        4 => TerminalProgressState::Pause,
        _ => return None,
    };
    let progress = if state == TerminalProgressState::Remove {
        None
    } else {
        params
            .get(3)
            .and_then(|value| parse_ascii_u8(value))
            .filter(|value| *value <= 100)
    };
    Some(TerminalProgressReport { state, progress })
}

fn parse_ascii_u8(value: &[u8]) -> Option<u8> {
    if value.is_empty() || !value.iter().all(u8::is_ascii_digit) {
        return None;
    }
    std::str::from_utf8(value).ok()?.parse().ok()
}

fn find_matches_in_line(line: &str, needle: &[char], case_sensitive: bool) -> Vec<usize> {
    let line_chars: Vec<char> = line.chars().collect();
    if needle.len() > line_chars.len() {
        return Vec::new();
    }

    let mut matches = Vec::new();
    for start in 0..=line_chars.len() - needle.len() {
        let matched = needle.iter().enumerate().all(|(offset, needle_char)| {
            chars_match(line_chars[start + offset], *needle_char, case_sensitive)
        });
        if matched {
            matches.push(start);
        }
    }
    matches
}

fn chars_match(lhs: char, rhs: char, case_sensitive: bool) -> bool {
    lhs == rhs || (!case_sensitive && lhs.eq_ignore_ascii_case(&rhs))
}

fn slice_columns(line: &str, start_column: usize, end_column: usize) -> String {
    line.chars()
        .skip(start_column)
        .take(end_column.saturating_sub(start_column))
        .collect()
}

fn trim_terminal_padding(text: &str) -> &str {
    text.trim_end_matches([' ', '\t'])
}
