use std::collections::HashSet;

use crate::layout::PaneId;

const DEFAULT_MAX_DEPTH: usize = 100;

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct PaneReference {
    pub worklane_id: String,
    pub pane_id: PaneId,
}

impl PaneReference {
    pub fn new(worklane_id: impl Into<String>, pane_id: PaneId) -> Self {
        Self {
            worklane_id: worklane_id.into(),
            pane_id,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PaneFocusHistory {
    back_stack: Vec<PaneReference>,
    forward_stack: Vec<PaneReference>,
    max_depth: usize,
}

impl Default for PaneFocusHistory {
    fn default() -> Self {
        Self::new(DEFAULT_MAX_DEPTH)
    }
}

impl PaneFocusHistory {
    pub fn new(max_depth: usize) -> Self {
        Self {
            back_stack: Vec::new(),
            forward_stack: Vec::new(),
            max_depth,
        }
    }

    pub fn back_stack(&self) -> &[PaneReference] {
        &self.back_stack
    }

    pub fn forward_stack(&self) -> &[PaneReference] {
        &self.forward_stack
    }

    pub fn can_go_back(&self) -> bool {
        !self.back_stack.is_empty()
    }

    pub fn can_go_forward(&self) -> bool {
        !self.forward_stack.is_empty()
    }

    pub fn recent_references(&self, all_pane_ids: &HashSet<PaneReference>) -> Vec<PaneReference> {
        let mut seen = HashSet::new();
        self.back_stack
            .iter()
            .rev()
            .filter(|reference| all_pane_ids.contains(*reference))
            .filter(|reference| seen.insert((*reference).clone()))
            .cloned()
            .collect()
    }

    pub fn record(&mut self, reference: PaneReference) {
        self.back_stack.push(reference);
        self.forward_stack.clear();

        if self.back_stack.len() > self.max_depth {
            self.back_stack
                .drain(0..self.back_stack.len() - self.max_depth);
        }
    }

    pub fn navigate_back(
        &mut self,
        current: PaneReference,
        all_pane_ids: &HashSet<PaneReference>,
    ) -> Option<PaneReference> {
        while let Some(entry) = self.back_stack.pop() {
            if all_pane_ids.contains(&entry) {
                self.forward_stack.push(current.clone());
                return Some(entry);
            }
        }
        None
    }

    pub fn navigate_forward(
        &mut self,
        current: PaneReference,
        all_pane_ids: &HashSet<PaneReference>,
    ) -> Option<PaneReference> {
        while let Some(entry) = self.forward_stack.pop() {
            if all_pane_ids.contains(&entry) {
                self.back_stack.push(current.clone());
                return Some(entry);
            }
        }
        None
    }
}
