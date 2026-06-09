use crate::screen::{TerminalScreen, TerminalSearchMatch, TerminalSearchOptions};

#[derive(Clone, Debug, Eq, PartialEq)]
#[derive(Default)]
pub struct TerminalSearchState {
    pub needle: String,
    pub selected: Option<usize>,
    pub total: usize,
    pub has_remembered_search: bool,
    pub is_hud_visible: bool,
}


#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TerminalSearchEvent {
    Started { needle: Option<String> },
    Ended,
    Total(usize),
    Selected(Option<usize>),
}

pub struct TerminalSearchSession {
    state: TerminalSearchState,
    matches: Vec<TerminalSearchMatch>,
    options: TerminalSearchOptions,
}

impl TerminalSearchSession {
    pub fn new() -> Self {
        Self {
            state: TerminalSearchState::default(),
            matches: Vec::new(),
            options: TerminalSearchOptions {
                case_sensitive: true,
            },
        }
    }

    pub fn with_options(options: TerminalSearchOptions) -> Self {
        Self {
            options,
            ..Self::new()
        }
    }

    pub fn state(&self) -> &TerminalSearchState {
        &self.state
    }

    pub fn matches(&self) -> &[TerminalSearchMatch] {
        &self.matches
    }

    pub fn current_match(&self) -> Option<&TerminalSearchMatch> {
        self.state
            .selected
            .and_then(|index| self.matches.get(index))
    }

    pub fn show_search(&mut self) -> Vec<TerminalSearchEvent> {
        self.state.is_hud_visible = true;
        vec![TerminalSearchEvent::Started {
            needle: remembered_needle(&self.state.needle),
        }]
    }

    pub fn update_query(
        &mut self,
        screen: &TerminalScreen,
        needle: &str,
    ) -> Vec<TerminalSearchEvent> {
        self.state.needle = needle.to_string();
        if !needle.is_empty() {
            self.state.has_remembered_search = true;
        }
        self.state.is_hud_visible = true;
        self.matches = screen.search(needle, self.options);
        self.state.selected = None;
        self.state.total = self.matches.len();

        vec![
            TerminalSearchEvent::Started {
                needle: remembered_needle(needle),
            },
            TerminalSearchEvent::Total(self.state.total),
            TerminalSearchEvent::Selected(None),
        ]
    }

    pub fn refresh_matches(&mut self, screen: &TerminalScreen) -> Vec<TerminalSearchEvent> {
        if self.state.needle.is_empty() {
            self.matches.clear();
            self.state.total = 0;
            self.state.selected = None;
            return vec![
                TerminalSearchEvent::Total(0),
                TerminalSearchEvent::Selected(None),
            ];
        }

        self.matches = screen.search(&self.state.needle, self.options);
        self.state.total = self.matches.len();
        self.state.selected = clamp_selection(self.state.selected, self.state.total);
        vec![
            TerminalSearchEvent::Total(self.state.total),
            TerminalSearchEvent::Selected(self.state.selected),
        ]
    }

    pub fn find_next(&mut self) -> Vec<TerminalSearchEvent> {
        if !self.state.has_remembered_search || self.matches.is_empty() {
            return Vec::new();
        }

        self.state.is_hud_visible = true;
        self.state.selected = Some(match self.state.selected {
            Some(selected) => (selected + 1) % self.matches.len(),
            None => 0,
        });
        vec![TerminalSearchEvent::Selected(self.state.selected)]
    }

    pub fn find_previous(&mut self) -> Vec<TerminalSearchEvent> {
        if !self.state.has_remembered_search || self.matches.is_empty() {
            return Vec::new();
        }

        self.state.is_hud_visible = true;
        self.state.selected = Some(match self.state.selected {
            Some(0) | None => self.matches.len() - 1,
            Some(selected) => selected - 1,
        });
        vec![TerminalSearchEvent::Selected(self.state.selected)]
    }

    pub fn hide_search(&mut self) {
        if self.state.has_remembered_search {
            self.state.is_hud_visible = false;
        }
    }

    pub fn end_search(&mut self) -> Vec<TerminalSearchEvent> {
        self.state = TerminalSearchState::default();
        self.matches.clear();
        vec![TerminalSearchEvent::Ended]
    }
}

impl Default for TerminalSearchSession {
    fn default() -> Self {
        Self::new()
    }
}

fn remembered_needle(needle: &str) -> Option<String> {
    (!needle.is_empty()).then(|| needle.to_string())
}

fn clamp_selection(selected: Option<usize>, total: usize) -> Option<usize> {
    match (selected, total) {
        (_, 0) => None,
        (Some(index), total) if index >= total => Some(total - 1),
        (selected, _) => selected,
    }
}
