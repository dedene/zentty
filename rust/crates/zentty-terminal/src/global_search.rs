use std::collections::{BTreeMap, BTreeSet};

use crate::search::TerminalSearchEvent;

#[derive(Clone, Debug, Eq, PartialEq)]
#[derive(Default)]
pub struct GlobalSearchState {
    pub needle: String,
    pub selected: Option<usize>,
    pub total: usize,
    pub has_remembered_search: bool,
    pub is_hud_visible: bool,
}


#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct GlobalSearchTarget {
    pub worklane_id: String,
    pub pane_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum GlobalSearchAction {
    EndAllLocalSearches,
    BeginPaneSearch { pane_id: String },
    UpdatePaneSearch { pane_id: String, needle: String },
    EndPaneSearch { pane_id: String },
    ResetPaneSelection { pane_id: String },
    NavigateToTarget(GlobalSearchTarget),
    PaneFindNext { pane_id: String },
    PaneFindPrevious { pane_id: String },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Direction {
    Next,
    Previous,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct PaneResultState {
    total: usize,
    selected: Option<usize>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct Selection {
    pane_id: String,
    index: usize,
}

pub struct GlobalSearchCoordinator {
    state: GlobalSearchState,
    frozen_targets: Vec<GlobalSearchTarget>,
    pane_results: BTreeMap<String, PaneResultState>,
    pending_pane_ids_awaiting_totals: BTreeSet<String>,
    current_selection: Option<Selection>,
    pending_navigation_direction: Option<Direction>,
    pending_query_update: bool,
}

impl GlobalSearchCoordinator {
    pub fn new(targets: Vec<GlobalSearchTarget>) -> Self {
        Self {
            state: GlobalSearchState::default(),
            pane_results: pane_results_for_targets(&targets),
            frozen_targets: targets,
            pending_pane_ids_awaiting_totals: BTreeSet::new(),
            current_selection: None,
            pending_navigation_direction: None,
            pending_query_update: false,
        }
    }

    pub fn state(&self) -> &GlobalSearchState {
        &self.state
    }

    pub fn update_query(&mut self, needle: &str) -> Vec<GlobalSearchAction> {
        let mut actions = Vec::new();
        if !self.state.has_remembered_search && !self.state.is_hud_visible {
            actions.push(GlobalSearchAction::EndAllLocalSearches);
        }

        self.clear_pane_results();
        self.pending_navigation_direction = None;
        self.pending_query_update = false;
        self.state.needle = needle.to_string();
        self.state.selected = None;
        self.state.total = 0;
        self.state.is_hud_visible = true;

        if needle.is_empty() {
            self.state.has_remembered_search = false;
            self.pending_pane_ids_awaiting_totals.clear();
            actions.extend(self.end_frozen_panes());
            return actions;
        }

        self.state.has_remembered_search = true;
        if needle.chars().count() >= 3 {
            actions.extend(self.dispatch_query_update());
        } else {
            self.pending_query_update = true;
        }
        actions
    }

    pub fn find_next(&mut self) -> Vec<GlobalSearchAction> {
        self.navigate(Direction::Next)
    }

    pub fn find_previous(&mut self) -> Vec<GlobalSearchAction> {
        self.navigate(Direction::Previous)
    }

    pub fn handle_search_event(
        &mut self,
        pane_id: &str,
        event: TerminalSearchEvent,
    ) -> Vec<GlobalSearchAction> {
        if !self.pane_results.contains_key(pane_id) {
            return Vec::new();
        }

        match event {
            TerminalSearchEvent::Started { .. } => Vec::new(),
            TerminalSearchEvent::Ended => {
                self.pane_results
                    .insert(pane_id.to_string(), PaneResultState::default());
                self.pending_pane_ids_awaiting_totals.remove(pane_id);
                if self
                    .current_selection
                    .as_ref()
                    .is_some_and(|selection| selection.pane_id == pane_id)
                {
                    self.current_selection = None;
                    self.state.selected = None;
                }
                self.recompute_total();
                Vec::new()
            }
            TerminalSearchEvent::Total(total) => {
                let pane_state = self.pane_results.entry(pane_id.to_string()).or_default();
                pane_state.total = total;
                self.pending_pane_ids_awaiting_totals.remove(pane_id);
                if self.current_selection.as_ref().is_some_and(|selection| {
                    selection.pane_id == pane_id && selection.index >= total
                }) {
                    self.current_selection = None;
                    pane_state.selected = None;
                    self.state.selected = None;
                }
                self.recompute_total();
                self.perform_pending_navigation_if_ready()
            }
            TerminalSearchEvent::Selected(selected) => {
                let Some(selected) = selected else {
                    if let Some(pane_state) = self.pane_results.get_mut(pane_id) {
                        pane_state.selected = None;
                    }
                    if self
                        .current_selection
                        .as_ref()
                        .is_some_and(|selection| selection.pane_id == pane_id)
                    {
                        self.current_selection = None;
                        self.state.selected = None;
                    }
                    return Vec::new();
                };

                self.set_selection(pane_id, selected);
                Vec::new()
            }
        }
    }

    pub fn end(&mut self) -> Vec<GlobalSearchAction> {
        let actions = self.end_frozen_panes();
        self.frozen_targets.clear();
        self.pane_results.clear();
        self.pending_pane_ids_awaiting_totals.clear();
        self.current_selection = None;
        self.pending_navigation_direction = None;
        self.pending_query_update = false;
        self.state = GlobalSearchState::default();
        actions
    }

    fn navigate(&mut self, direction: Direction) -> Vec<GlobalSearchAction> {
        if !self.state.has_remembered_search {
            return Vec::new();
        }

        self.state.is_hud_visible = true;
        let mut actions = self.flush_pending_query_update_if_needed();
        if self.state.total == 0 {
            if !self.pending_pane_ids_awaiting_totals.is_empty() {
                self.pending_navigation_direction = Some(direction);
            }
            return actions;
        }
        self.pending_navigation_direction = None;

        let live_targets = self.frozen_targets.clone();
        if live_targets.is_empty() {
            return actions;
        }

        let Some(current_selection) = self.current_selection.clone() else {
            actions.extend(self.navigate_from_unselected(direction, &live_targets));
            return actions;
        };

        let Some(current_target_index) = live_targets
            .iter()
            .position(|target| target.pane_id == current_selection.pane_id)
        else {
            self.current_selection = None;
            self.state.selected = None;
            actions.extend(self.navigate_from_unselected(direction, &live_targets));
            return actions;
        };
        let current_pane_state = self
            .pane_results
            .get(&current_selection.pane_id)
            .cloned()
            .unwrap_or_default();

        match direction {
            Direction::Next if current_selection.index + 1 < current_pane_state.total => {
                self.set_selection(&current_selection.pane_id, current_selection.index + 1);
                actions.push(GlobalSearchAction::PaneFindNext {
                    pane_id: current_selection.pane_id,
                });
                return actions;
            }
            Direction::Previous if current_selection.index > 0 => {
                self.set_selection(&current_selection.pane_id, current_selection.index - 1);
                actions.push(GlobalSearchAction::PaneFindPrevious {
                    pane_id: current_selection.pane_id,
                });
                return actions;
            }
            _ => {}
        }

        let Some(target) = self.next_pane_target(current_target_index, direction, &live_targets)
        else {
            return actions;
        };

        if target.pane_id == current_selection.pane_id {
            let selected_index = match direction {
                Direction::Next => 0,
                Direction::Previous => current_pane_state.total.saturating_sub(1),
            };
            self.set_selection(&target.pane_id, selected_index);
            actions.push(find_action(direction, &target.pane_id));
            return actions;
        }

        actions.push(GlobalSearchAction::ResetPaneSelection {
            pane_id: current_selection.pane_id,
        });
        let selected_index = match direction {
            Direction::Next => 0,
            Direction::Previous => self
                .pane_results
                .get(&target.pane_id)
                .map_or(0, |pane| pane.total.saturating_sub(1)),
        };
        self.set_selection(&target.pane_id, selected_index);
        actions.push(GlobalSearchAction::NavigateToTarget(target.clone()));
        actions.push(find_action(direction, &target.pane_id));
        actions
    }

    fn navigate_from_unselected(
        &mut self,
        direction: Direction,
        live_targets: &[GlobalSearchTarget],
    ) -> Vec<GlobalSearchAction> {
        let target = match direction {
            Direction::Next => live_targets
                .iter()
                .find(|target| self.pane_total(&target.pane_id) > 0),
            Direction::Previous => live_targets
                .iter()
                .rev()
                .find(|target| self.pane_total(&target.pane_id) > 0),
        };
        let Some(target) = target else {
            return Vec::new();
        };

        let selected_index = match direction {
            Direction::Next => 0,
            Direction::Previous => self.pane_total(&target.pane_id).saturating_sub(1),
        };
        self.set_selection(&target.pane_id, selected_index);
        vec![
            GlobalSearchAction::NavigateToTarget(target.clone()),
            find_action(direction, &target.pane_id),
        ]
    }

    fn next_pane_target(
        &self,
        current_index: usize,
        direction: Direction,
        live_targets: &[GlobalSearchTarget],
    ) -> Option<GlobalSearchTarget> {
        if live_targets.is_empty() {
            return None;
        }

        for offset in 1..=live_targets.len() {
            let index = match direction {
                Direction::Next => (current_index + offset) % live_targets.len(),
                Direction::Previous => {
                    (current_index + live_targets.len() - offset) % live_targets.len()
                }
            };
            let target = &live_targets[index];
            if self.pane_total(&target.pane_id) > 0 {
                return Some(target.clone());
            }
        }
        None
    }

    fn dispatch_query_update(&mut self) -> Vec<GlobalSearchAction> {
        self.pending_query_update = false;
        self.pending_pane_ids_awaiting_totals.clear();
        let mut actions = Vec::new();
        for target in &self.frozen_targets {
            self.pending_pane_ids_awaiting_totals
                .insert(target.pane_id.clone());
            actions.push(GlobalSearchAction::BeginPaneSearch {
                pane_id: target.pane_id.clone(),
            });
            actions.push(GlobalSearchAction::UpdatePaneSearch {
                pane_id: target.pane_id.clone(),
                needle: self.state.needle.clone(),
            });
        }
        actions
    }

    fn clear_pane_results(&mut self) {
        self.pane_results = pane_results_for_targets(&self.frozen_targets);
        self.pending_pane_ids_awaiting_totals.clear();
        self.current_selection = None;
    }

    fn recompute_total(&mut self) {
        self.state.total = self.pane_results.values().map(|pane| pane.total).sum();
        if self.state.total == 0 {
            self.state.selected = None;
        }
    }

    fn global_ordinal(&self, pane_id: &str, selected_index: usize) -> Option<usize> {
        let mut offset = 0;
        for target in &self.frozen_targets {
            let pane_state = self.pane_results.get(&target.pane_id)?;
            if target.pane_id == pane_id {
                return Some(offset + selected_index);
            }
            offset += pane_state.total;
        }
        None
    }

    fn set_selection(&mut self, pane_id: &str, selected_index: usize) {
        for (target_pane_id, pane_state) in &mut self.pane_results {
            pane_state.selected = (target_pane_id == pane_id).then_some(selected_index);
        }
        self.current_selection = Some(Selection {
            pane_id: pane_id.to_string(),
            index: selected_index,
        });
        self.state.selected = self.global_ordinal(pane_id, selected_index);
    }

    fn flush_pending_query_update_if_needed(&mut self) -> Vec<GlobalSearchAction> {
        if self.pending_query_update {
            self.dispatch_query_update()
        } else {
            Vec::new()
        }
    }

    fn perform_pending_navigation_if_ready(&mut self) -> Vec<GlobalSearchAction> {
        if self.pending_pane_ids_awaiting_totals.is_empty()
            && self.state.total > 0
            && self.pending_navigation_direction.is_some()
        {
            let direction = self
                .pending_navigation_direction
                .take()
                .expect("checked for pending navigation direction");
            return self.navigate(direction);
        }
        Vec::new()
    }

    fn end_frozen_panes(&self) -> Vec<GlobalSearchAction> {
        self.frozen_targets
            .iter()
            .map(|target| GlobalSearchAction::EndPaneSearch {
                pane_id: target.pane_id.clone(),
            })
            .collect()
    }

    fn pane_total(&self, pane_id: &str) -> usize {
        self.pane_results.get(pane_id).map_or(0, |pane| pane.total)
    }
}

fn pane_results_for_targets(targets: &[GlobalSearchTarget]) -> BTreeMap<String, PaneResultState> {
    targets
        .iter()
        .map(|target| (target.pane_id.clone(), PaneResultState::default()))
        .collect()
}

fn find_action(direction: Direction, pane_id: &str) -> GlobalSearchAction {
    match direction {
        Direction::Next => GlobalSearchAction::PaneFindNext {
            pane_id: pane_id.to_string(),
        },
        Direction::Previous => GlobalSearchAction::PaneFindPrevious {
            pane_id: pane_id.to_string(),
        },
    }
}
