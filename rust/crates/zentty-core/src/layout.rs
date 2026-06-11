use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub struct PaneId(String);

impl PaneId {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl From<&str> for PaneId {
    fn from(value: &str) -> Self {
        Self(value.to_string())
    }
}

impl From<String> for PaneId {
    fn from(value: String) -> Self {
        Self(value)
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub struct PaneColumnId(String);

impl PaneColumnId {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl From<&str> for PaneColumnId {
    fn from(value: &str) -> Self {
        Self(value.to_string())
    }
}

impl From<String> for PaneColumnId {
    fn from(value: String) -> Self {
        Self(value)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PanePlacement {
    BeforeFocused,
    AfterFocused,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct PaneLayoutSizing {
    pub horizontal_inset: f64,
    pub top_inset: f64,
    pub bottom_inset: f64,
    pub inter_pane_spacing: f64,
}

impl PaneLayoutSizing {
    pub const BALANCED: Self = Self {
        horizontal_inset: 0.0,
        top_inset: 2.0,
        bottom_inset: 0.0,
        inter_pane_spacing: 6.0,
    };

    pub fn pane_height(&self, container_height: f64) -> f64 {
        (container_height - self.top_inset - self.bottom_inset).max(0.0)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[derive(Default)]
pub struct TerminalSessionRequest {
    pub working_directory: Option<String>,
    pub command: Option<String>,
    pub native_command: Option<String>,
    pub wait_after_native_command: bool,
    pub is_launch_deferred: bool,
    pub prefill_text: Option<String>,
    pub inherit_from_pane_id: Option<PaneId>,
    pub config_inheritance_source_pane_id: Option<PaneId>,
    pub environment_variables: Vec<(String, String)>,
}


#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PaneState {
    id: PaneId,
    title: String,
    pub session_request: TerminalSessionRequest,
    pub width: f64,
}

impl PaneState {
    pub fn new(id: PaneId, title: impl Into<String>) -> Self {
        Self {
            id,
            title: title.into(),
            session_request: TerminalSessionRequest::default(),
            width: 500.0,
        }
    }

    pub fn id(&self) -> &PaneId {
        &self.id
    }

    pub fn title(&self) -> &str {
        &self.title
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PaneColumnState {
    id: PaneColumnId,
    panes: Vec<PaneState>,
    pub width: f64,
    pane_heights: Vec<f64>,
    focused_pane_id: Option<PaneId>,
    last_focused_pane_id: Option<PaneId>,
}

impl PaneColumnState {
    pub fn new(
        id: PaneColumnId,
        panes: Vec<PaneState>,
        width: f64,
        pane_heights: Vec<f64>,
        focused_pane_id: Option<PaneId>,
        last_focused_pane_id: Option<PaneId>,
    ) -> Self {
        let focused = Self::resolve_pane_id(&panes, focused_pane_id.as_ref());
        let last_focused_preference = last_focused_pane_id.as_ref().or(focused_pane_id.as_ref());
        let last_focused = Self::resolve_pane_id(&panes, last_focused_preference);
        Self {
            id,
            pane_heights: Self::resolved_stored_pane_heights(&pane_heights, panes.len()),
            panes,
            width: width.max(1.0),
            focused_pane_id: focused,
            last_focused_pane_id: last_focused,
        }
    }

    pub fn id(&self) -> &PaneColumnId {
        &self.id
    }

    pub fn panes(&self) -> &[PaneState] {
        &self.panes
    }

    pub fn pane_heights(&self) -> &[f64] {
        &self.pane_heights
    }

    pub fn focused_pane_id(&self) -> Option<&PaneId> {
        self.focused_pane_id.as_ref()
    }

    pub fn last_focused_pane_id(&self) -> Option<&PaneId> {
        self.last_focused_pane_id.as_ref()
    }

    pub fn focused_pane(&self) -> Option<&PaneState> {
        let focused = self.focused_pane_id.as_ref()?;
        self.panes.iter().find(|pane| pane.id() == focused)
    }

    pub fn focused_pane_index(&self) -> usize {
        self.focused_pane_id
            .as_ref()
            .and_then(|id| self.panes.iter().position(|pane| pane.id() == id))
            .unwrap_or(0)
    }

    pub fn focus_pane(&mut self, id: &PaneId) {
        if self.panes.iter().any(|pane| pane.id() == id) {
            self.focused_pane_id = Some(id.clone());
            self.last_focused_pane_id = Some(id.clone());
        }
    }

    fn restore_last_focused_pane(&mut self) {
        let preferred = self
            .last_focused_pane_id
            .as_ref()
            .or(self.focused_pane_id.as_ref());
        let restored = Self::resolve_pane_id(&self.panes, preferred);
        self.focused_pane_id = restored.clone();
        if restored.is_some() {
            self.last_focused_pane_id = restored;
        }
    }

    fn move_focus_by(&mut self, delta: isize) {
        if self.panes.is_empty() {
            self.focused_pane_id = None;
            self.last_focused_pane_id = None;
            return;
        }

        let next = (self.focused_pane_index() as isize + delta)
            .clamp(0, self.panes.len() as isize - 1) as usize;
        let next_id = self.panes[next].id().clone();
        self.focus_pane(&next_id);
    }

    pub fn move_focus_up(&mut self) {
        self.move_focus_by(-1);
    }

    pub fn move_focus_down(&mut self) {
        self.move_focus_by(1);
    }

    pub fn insert_pane_vertically(&mut self, pane: PaneState, placement: PanePlacement) {
        if self.panes.is_empty() {
            let pane_id = pane.id().clone();
            self.panes = vec![pane];
            self.pane_heights = vec![1.0];
            self.focus_pane(&pane_id);
            return;
        }

        let source_index = self
            .focused_pane_index()
            .min(self.pane_heights.len().saturating_sub(1));
        let insertion_index = match placement {
            PanePlacement::AfterFocused => (source_index + 1).min(self.panes.len()),
            PanePlacement::BeforeFocused => source_index,
        };
        let source_height = self.pane_heights[source_index];
        let inserted_height = (source_height / 2.0).max(1.0);
        let retained_height = (source_height - inserted_height).max(1.0);
        let pane_id = pane.id().clone();

        self.pane_heights[source_index] = retained_height;
        self.pane_heights.insert(insertion_index, inserted_height);
        self.panes.insert(insertion_index, pane);
        self.reconcile_pane_heights();
        self.focus_pane(&pane_id);
    }

    fn equalize_pane_heights(&mut self) {
        self.pane_heights = vec![1.0; self.panes.len()];
    }

    fn reconcile_pane_heights(&mut self) {
        self.pane_heights =
            Self::resolved_stored_pane_heights(&self.pane_heights, self.panes.len());
    }

    fn resolve_pane_id(panes: &[PaneState], preferred: Option<&PaneId>) -> Option<PaneId> {
        match preferred {
            Some(id) if panes.iter().any(|pane| pane.id() == id) => Some(id.clone()),
            _ => panes.first().map(|pane| pane.id().clone()),
        }
    }

    fn resolved_stored_pane_heights(preferred: &[f64], pane_count: usize) -> Vec<f64> {
        if pane_count == 0 {
            return Vec::new();
        }
        let sanitized: Vec<f64> = preferred
            .iter()
            .take(pane_count)
            .map(|height| height.max(1.0))
            .collect();
        if sanitized.len() == pane_count {
            sanitized
        } else {
            vec![1.0; pane_count]
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PaneRemoval {
    pub pane: PaneState,
    pub from_column_id: PaneColumnId,
    pub column_index: usize,
    pub pane_index: usize,
    pub pane_height: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PaneStripState {
    columns: Vec<PaneColumnState>,
    focused_column_id: Option<PaneColumnId>,
    pub layout_sizing: PaneLayoutSizing,
}

impl PaneStripState {
    pub const MINIMUM_VERTICAL_PANE_HEIGHT: f64 = 160.0;

    pub fn new(columns: Vec<PaneColumnState>, focused_column_id: Option<PaneColumnId>) -> Self {
        let columns: Vec<PaneColumnState> = columns
            .into_iter()
            .filter(|column| !column.panes.is_empty())
            .collect();
        let focused_column_id =
            Self::resolve_focused_column_id(&columns, focused_column_id.as_ref());
        let mut state = Self {
            columns,
            focused_column_id,
            layout_sizing: PaneLayoutSizing::BALANCED,
        };
        state.restore_column_focus_if_needed();
        state
    }

    pub fn columns(&self) -> &[PaneColumnState] {
        &self.columns
    }

    pub fn focused_column(&self) -> Option<&PaneColumnState> {
        let focused = self.focused_column_id.as_ref()?;
        self.columns.iter().find(|column| column.id() == focused)
    }

    pub fn focused_column_id(&self) -> Option<&PaneColumnId> {
        self.focused_column_id.as_ref()
    }

    pub fn pane_count(&self) -> usize {
        self.columns.iter().map(|column| column.panes.len()).sum()
    }

    pub fn focused_pane(&self) -> Option<&PaneState> {
        self.focused_column()?.focused_pane()
    }

    pub fn focused_pane_id(&self) -> Option<&PaneId> {
        self.focused_column()?.focused_pane_id()
    }

    pub fn focus_pane(&mut self, id: &PaneId) -> bool {
        let Some(column_index) = self
            .columns
            .iter()
            .position(|column| column.panes.iter().any(|pane| pane.id() == id))
        else {
            return false;
        };
        self.columns[column_index].focus_pane(id);
        self.focused_column_id = Some(self.columns[column_index].id().clone());
        true
    }

    fn focused_column_index(&self) -> Option<usize> {
        let focused = self.focused_column_id.as_ref()?;
        self.columns
            .iter()
            .position(|column| column.id() == focused)
    }

    pub fn move_focus_right(&mut self) {
        self.move_column_focus_by(1);
    }

    pub fn move_focus_left(&mut self) {
        self.move_column_focus_by(-1);
    }

    pub fn move_focus_up(&mut self) {
        if let Some(index) = self.focused_column_index() {
            self.columns[index].move_focus_up();
        }
    }

    pub fn move_focus_down(&mut self) {
        if let Some(index) = self.focused_column_index() {
            self.columns[index].move_focus_down();
        }
    }

    pub fn insert_pane_vertically(
        &mut self,
        pane: PaneState,
        column_id: Option<&PaneColumnId>,
        placement: PanePlacement,
        available_height: f64,
        minimum_pane_height: f64,
    ) -> bool {
        let target_column_id = column_id
            .cloned()
            .or_else(|| self.focused_column_id.clone());
        let Some(target_column_id) = target_column_id else {
            return false;
        };
        let Some(target_index) = self
            .columns
            .iter()
            .position(|column| column.id() == &target_column_id)
        else {
            return false;
        };

        let next_pane_count = self.columns[target_index].panes.len() + 1;
        let equalized_height = self.resolved_pane_height(available_height, next_pane_count);
        if equalized_height < minimum_pane_height.max(1.0) {
            return false;
        }

        self.columns[target_index].insert_pane_vertically(pane, placement);
        self.focused_column_id = Some(self.columns[target_index].id().clone());
        true
    }

    pub fn move_pane(
        &mut self,
        id: &PaneId,
        to_column_id: &PaneColumnId,
        pane_index: usize,
    ) -> bool {
        let Some(source_column_index) = self
            .columns
            .iter()
            .position(|column| column.panes.iter().any(|pane| pane.id() == id))
        else {
            return false;
        };
        let Some(source_pane_index) = self.columns[source_column_index]
            .panes
            .iter()
            .position(|pane| pane.id() == id)
        else {
            return false;
        };
        let Some(target_column_index) = self
            .columns
            .iter()
            .position(|column| column.id() == to_column_id)
        else {
            return false;
        };

        if source_column_index == target_column_index {
            let pane = self.columns[source_column_index]
                .panes
                .remove(source_pane_index);
            let pane_height = self.columns[source_column_index]
                .pane_heights
                .remove(source_pane_index);
            let insertion_index = pane_index.min(self.columns[source_column_index].panes.len());
            if insertion_index == source_pane_index {
                self.columns[source_column_index]
                    .panes
                    .insert(source_pane_index, pane);
                self.columns[source_column_index]
                    .pane_heights
                    .insert(source_pane_index, pane_height);
            } else {
                self.columns[source_column_index]
                    .panes
                    .insert(insertion_index, pane);
                self.columns[source_column_index]
                    .pane_heights
                    .insert(insertion_index, pane_height);
                self.columns[source_column_index].reconcile_pane_heights();
            }
            let pane_id = id.clone();
            self.columns[source_column_index].focus_pane(&pane_id);
            self.focused_column_id = Some(self.columns[source_column_index].id().clone());
            return true;
        }

        let Some(removal) = self.remove_pane(id) else {
            return false;
        };
        if self.insert_existing_pane_into_column(removal.pane.clone(), to_column_id, pane_index) {
            true
        } else {
            self.insert_pane_as_column(removal.pane, removal.column_index, removal.pane_height);
            false
        }
    }

    pub(crate) fn remove_pane(&mut self, id: &PaneId) -> Option<PaneRemoval> {
        let column_index = self
            .columns
            .iter()
            .position(|column| column.panes.iter().any(|pane| pane.id() == id))?;
        let column_id = self.columns[column_index].id().clone();
        let pane_index = self.columns[column_index]
            .panes
            .iter()
            .position(|pane| pane.id() == id)?;

        if self.columns[column_index].panes.len() > 1 {
            let mut pane = self.columns[column_index].panes.remove(pane_index);
            pane.width = self.columns[column_index].width;
            let removed_height = if pane_index < self.columns[column_index].pane_heights.len() {
                self.columns[column_index].pane_heights.remove(pane_index)
            } else {
                1.0
            };
            let next_index = if pane_index < self.columns[column_index].panes.len() {
                pane_index
            } else {
                self.columns[column_index].panes.len() - 1
            };
            if self.columns[column_index].focused_pane_id.as_ref() == Some(id) {
                let next_id = self.columns[column_index].panes[next_index].id().clone();
                self.columns[column_index].focus_pane(&next_id);
            }
            if next_index < self.columns[column_index].pane_heights.len() {
                self.columns[column_index].pane_heights[next_index] += removed_height;
            }
            self.columns[column_index].reconcile_pane_heights();
            return Some(PaneRemoval {
                pane,
                from_column_id: column_id,
                column_index,
                pane_index,
                pane_height: removed_height,
            });
        }

        let mut pane = self.columns[column_index].panes.remove(0);
        pane.width = self.columns[column_index].width;
        let removed_height = self.columns[column_index]
            .pane_heights
            .first()
            .copied()
            .unwrap_or(1.0);
        self.columns.remove(column_index);
        if self.columns.is_empty() {
            self.focused_column_id = None;
        } else if self.focused_column_id.as_ref() == Some(&column_id) {
            let next_column_index = column_index.min(self.columns.len() - 1);
            self.focused_column_id = Some(self.columns[next_column_index].id().clone());
            self.restore_column_focus_if_needed();
        }
        Some(PaneRemoval {
            pane,
            from_column_id: column_id,
            column_index,
            pane_index,
            pane_height: removed_height,
        })
    }

    pub(crate) fn insert_existing_pane_into_column(
        &mut self,
        pane: PaneState,
        column_id: &PaneColumnId,
        pane_index: usize,
    ) -> bool {
        let Some(column_index) = self
            .columns
            .iter()
            .position(|column| column.id() == column_id)
        else {
            return false;
        };
        let insertion_index = pane_index.min(self.columns[column_index].panes.len());
        let pane_id = pane.id().clone();
        self.columns[column_index]
            .panes
            .insert(insertion_index, pane);
        self.columns[column_index].equalize_pane_heights();
        self.columns[column_index].focus_pane(&pane_id);
        self.focused_column_id = Some(self.columns[column_index].id().clone());
        true
    }

    pub(crate) fn insert_pane_as_column(
        &mut self,
        pane: PaneState,
        column_index: usize,
        width: f64,
    ) {
        let pane_id = pane.id().clone();
        let column_id = self.unique_column_id(&pane_id);
        let new_column = PaneColumnState::new(
            column_id,
            vec![pane],
            width,
            Vec::new(),
            Some(pane_id.clone()),
            Some(pane_id),
        );
        let insertion_index = column_index.min(self.columns.len());
        self.columns.insert(insertion_index, new_column);
        self.focused_column_id = Some(self.columns[insertion_index].id().clone());
    }

    pub(crate) fn set_pane_height(
        &mut self,
        column_index: usize,
        pane_id: &PaneId,
        height: f64,
    ) -> bool {
        if height <= 0.0 || column_index >= self.columns.len() {
            return false;
        }
        let Some(pane_index) = self.columns[column_index]
            .panes
            .iter()
            .position(|pane| pane.id() == pane_id)
        else {
            return false;
        };
        if pane_index >= self.columns[column_index].pane_heights.len() {
            return false;
        }
        self.columns[column_index].pane_heights[pane_index] = height;
        true
    }

    fn move_column_focus_by(&mut self, delta: isize) {
        if self.columns.is_empty() {
            self.focused_column_id = None;
            return;
        }
        let current = self.focused_column_index().unwrap_or(0);
        let next = (current as isize + delta).clamp(0, self.columns.len() as isize - 1) as usize;
        self.focused_column_id = Some(self.columns[next].id().clone());
        self.restore_column_focus_if_needed();
    }

    fn restore_column_focus_if_needed(&mut self) {
        if let Some(index) = self.focused_column_index() {
            self.columns[index].restore_last_focused_pane();
        }
    }

    fn resolve_focused_column_id(
        columns: &[PaneColumnState],
        preferred: Option<&PaneColumnId>,
    ) -> Option<PaneColumnId> {
        match preferred {
            Some(id) if columns.iter().any(|column| column.id() == id) => Some(id.clone()),
            _ => columns.first().map(|column| column.id().clone()),
        }
    }

    fn resolved_pane_height(&self, total_height: f64, pane_count: usize) -> f64 {
        if pane_count == 0 {
            return 0.0;
        }
        let total_spacing =
            self.layout_sizing.inter_pane_spacing * pane_count.saturating_sub(1) as f64;
        (total_height - total_spacing).max(0.0) / pane_count as f64
    }

    fn unique_column_id(&self, pane_id: &PaneId) -> PaneColumnId {
        let base = format!("column-{}", pane_id.as_str());
        if self
            .columns
            .iter()
            .all(|column| column.id().as_str() != base)
        {
            return PaneColumnId::from(base);
        }
        let mut suffix = 2;
        loop {
            let candidate = format!("{base}-{suffix}");
            if self
                .columns
                .iter()
                .all(|column| column.id().as_str() != candidate)
            {
                return PaneColumnId::from(candidate);
            }
            suffix += 1;
        }
    }
}
