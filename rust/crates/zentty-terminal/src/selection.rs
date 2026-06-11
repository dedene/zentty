use crate::screen::{TerminalScreen, TerminalTextPoint, TerminalTextRange};

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct TerminalSelection {
    anchor: Option<TerminalTextPoint>,
    focus: Option<TerminalTextPoint>,
}

impl TerminalSelection {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn begin(&mut self, point: TerminalTextPoint) {
        self.anchor = Some(point);
        self.focus = Some(point);
    }

    pub fn extend(&mut self, point: TerminalTextPoint) {
        if self.anchor.is_none() {
            self.anchor = Some(point);
        }
        self.focus = Some(point);
    }

    pub fn clear(&mut self) {
        self.anchor = None;
        self.focus = None;
    }

    pub fn range(&self) -> Option<TerminalTextRange> {
        let anchor = self.anchor?;
        let focus = self.focus?;
        if anchor == focus {
            return None;
        }

        let (start, end) = if anchor <= focus {
            (anchor, focus)
        } else {
            (focus, anchor)
        };
        Some(TerminalTextRange { start, end })
    }

    pub fn selected_text(&self, screen: &TerminalScreen) -> Option<String> {
        let text = screen.text_in_range(self.range()?)?;
        (!text.is_empty()).then_some(text)
    }

    pub fn search_seed(&self, screen: &TerminalScreen) -> Option<String> {
        let text = self.selected_text(screen)?;
        if text.contains('\n') {
            return None;
        }
        let trimmed = text.trim().to_string();
        (!trimmed.is_empty()).then_some(trimmed)
    }

    pub fn select_word_at(&mut self, screen: &TerminalScreen, point: TerminalTextPoint) -> bool {
        let Some(line) = screen.all_lines().get(point.line_index).cloned() else {
            self.clear();
            return false;
        };
        let chars: Vec<char> = line.chars().collect();
        if point.column >= chars.len() || chars[point.column].is_whitespace() {
            self.clear();
            return false;
        }

        let mut start = point.column;
        while start > 0 && !chars[start - 1].is_whitespace() {
            start -= 1;
        }

        let mut end = point.column + 1;
        while end < chars.len() && !chars[end].is_whitespace() {
            end += 1;
        }

        self.anchor = Some(TerminalTextPoint {
            line_index: point.line_index,
            column: start,
        });
        self.focus = Some(TerminalTextPoint {
            line_index: point.line_index,
            column: end,
        });
        true
    }

    pub fn select_line(&mut self, screen: &TerminalScreen, line_index: usize) -> bool {
        let Some(line) = screen.all_lines().get(line_index).cloned() else {
            self.clear();
            return false;
        };
        let width = line.chars().count();
        if width == 0 {
            self.clear();
            return false;
        }

        self.anchor = Some(TerminalTextPoint {
            line_index,
            column: 0,
        });
        self.focus = Some(TerminalTextPoint {
            line_index,
            column: width,
        });
        true
    }
}
