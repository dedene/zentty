use std::cmp::Ordering;
use std::collections::BTreeMap;
use std::error::Error;
use std::fmt;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
use uuid::Uuid;

use crate::command_palette::FuzzyMatcher;

const GENERATED_TEMPLATE_ENVIRONMENT_KEYS: [&str; 6] = [
    "PATH",
    "ZDOTDIR",
    "PROMPT_COMMAND",
    "GHOSTTY_LOG",
    "COLORTERM",
    "XDG_DATA_DIRS",
];

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum WorkspaceTemplateKind {
    Bookmark,
    Preset,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceTemplate {
    pub schema_version: i32,
    pub id: String,
    pub name: String,
    pub kind: WorkspaceTemplateKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_root: Option<String>,
    pub next_pane_number: i32,
    #[serde(rename = "focusedColumnID", skip_serializing_if = "Option::is_none")]
    pub focused_column_id: Option<String>,
    pub columns: Vec<WorkspaceTemplateColumn>,
    pub pinned: bool,
    pub created_at: String,
    pub updated_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_used_at: Option<String>,
}

impl WorkspaceTemplate {
    pub const CURRENT_SCHEMA_VERSION: i32 = 1;

    pub fn new(name: impl Into<String>, kind: WorkspaceTemplateKind) -> Self {
        let now = now_iso8601();
        Self {
            schema_version: Self::CURRENT_SCHEMA_VERSION,
            id: Uuid::new_v4().to_string(),
            name: name.into(),
            kind,
            title: None,
            color: None,
            project_root: None,
            next_pane_number: 1,
            focused_column_id: None,
            columns: Vec::new(),
            pinned: false,
            created_at: now.clone(),
            updated_at: now,
            last_used_at: None,
        }
    }

    pub fn pane_count(&self) -> usize {
        self.columns.iter().map(|column| column.panes.len()).sum()
    }

    pub fn all_panes(&self) -> Vec<&WorkspaceTemplatePane> {
        self.columns
            .iter()
            .flat_map(|column| column.panes.iter())
            .collect()
    }

    pub fn stripping_working_directories(&self) -> Self {
        let mut copy = self.clone();
        copy.kind = WorkspaceTemplateKind::Preset;
        copy.project_root = None;
        for column in &mut copy.columns {
            for pane in &mut column.panes {
                pane.working_directory = None;
            }
        }
        copy.updated_at = now_iso8601();
        copy
    }

    pub fn stripping_unsafe_environment(&self) -> Self {
        let mut copy = self.clone();
        for column in &mut copy.columns {
            for pane in &mut column.panes {
                pane.environment = template_safe_environment_overrides(&pane.environment);
            }
        }
        copy.updated_at = now_iso8601();
        copy
    }

    pub fn fresh_preset_copy(&self, name: impl Into<String>) -> Self {
        let name = name.into();
        let now = now_iso8601();
        let mut copy = self
            .stripping_working_directories()
            .stripping_unsafe_environment();
        copy.id = Uuid::new_v4().to_string();
        copy.name = trimmed_non_empty(&name)
            .unwrap_or("Untitled preset")
            .to_string();
        copy.kind = WorkspaceTemplateKind::Preset;
        copy.project_root = None;
        copy.pinned = false;
        copy.created_at = now.clone();
        copy.updated_at = now;
        copy.last_used_at = None;
        copy
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceTemplateColumn {
    pub id: String,
    pub width: f64,
    #[serde(rename = "focusedPaneID", skip_serializing_if = "Option::is_none")]
    pub focused_pane_id: Option<String>,
    #[serde(rename = "lastFocusedPaneID", skip_serializing_if = "Option::is_none")]
    pub last_focused_pane_id: Option<String>,
    pub pane_heights: Vec<f64>,
    pub panes: Vec<WorkspaceTemplatePane>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceTemplatePane {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title_seed: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub working_directory: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub environment: BTreeMap<String, String>,
    pub was_user_edited: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct WorkspaceTemplateCaptureInput {
    pub name: String,
    pub kind: WorkspaceTemplateKind,
    pub title: Option<String>,
    pub color: Option<String>,
    pub next_pane_number: i32,
    pub focused_column_id: Option<String>,
    pub columns: Vec<WorkspaceTemplateCaptureColumn>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct WorkspaceTemplateCaptureColumn {
    pub id: String,
    pub width: f64,
    pub focused_pane_id: Option<String>,
    pub last_focused_pane_id: Option<String>,
    pub pane_heights: Vec<f64>,
    pub panes: Vec<WorkspaceTemplateCapturePane>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceTemplateCapturePane {
    pub id: String,
    pub title_seed: Option<String>,
    pub working_directory: Option<String>,
    pub command: Option<String>,
    pub environment: BTreeMap<String, String>,
}

pub struct WorkspaceTemplateCapture;

impl WorkspaceTemplateCapture {
    pub fn capture(input: WorkspaceTemplateCaptureInput) -> WorkspaceTemplate {
        let columns = input
            .columns
            .into_iter()
            .map(|column| WorkspaceTemplateColumn {
                id: column.id,
                width: column.width,
                focused_pane_id: column.focused_pane_id,
                last_focused_pane_id: column.last_focused_pane_id,
                pane_heights: column.pane_heights,
                panes: column
                    .panes
                    .into_iter()
                    .map(|pane| WorkspaceTemplatePane {
                        id: pane.id,
                        title_seed: trimmed_owned(pane.title_seed.as_deref()),
                        working_directory: (input.kind == WorkspaceTemplateKind::Bookmark)
                            .then(|| trimmed_owned(pane.working_directory.as_deref()))
                            .flatten(),
                        command: trimmed_owned(pane.command.as_deref()),
                        environment: template_safe_environment_overrides(&pane.environment),
                        was_user_edited: false,
                    })
                    .collect(),
            })
            .collect::<Vec<_>>();
        let working_directories = columns
            .iter()
            .flat_map(|column| column.panes.iter())
            .filter_map(|pane| pane.working_directory.clone())
            .collect::<Vec<_>>();

        let mut template = WorkspaceTemplate::new(input.name.trim(), input.kind);
        template.title = trimmed_owned(input.title.as_deref());
        template.color = trimmed_owned(input.color.as_deref());
        template.project_root = (input.kind == WorkspaceTemplateKind::Bookmark)
            .then(|| Self::longest_common_ancestor(&working_directories))
            .flatten();
        template.next_pane_number = input.next_pane_number.max(1);
        template.focused_column_id = input.focused_column_id;
        template.columns = columns;
        template
    }

    pub fn longest_common_ancestor(paths: &[String]) -> Option<String> {
        let normalized = paths
            .iter()
            .filter_map(|path| trimmed_non_empty(path))
            .map(path_components_for_common_ancestor)
            .filter(|components| !components.is_empty())
            .collect::<Vec<_>>();
        let first = normalized.first()?;
        if normalized.len() == 1 {
            return Some(path_from_components(first));
        }

        let mut common_prefix_len = first.len();
        for components in normalized.iter().skip(1) {
            common_prefix_len = common_prefix_len.min(components.len());
            let mut matched = 0;
            while matched < common_prefix_len
                && path_component_equal(&first[matched], &components[matched])
            {
                matched += 1;
            }
            common_prefix_len = matched;
            if common_prefix_len == 0 {
                return None;
            }
        }

        Some(path_from_components(&first[..common_prefix_len]))
    }
}

pub struct BookmarkNameSuggester;

impl BookmarkNameSuggester {
    pub fn suggest(
        kind: WorkspaceTemplateKind,
        title: Option<&str>,
        pane_working_directories: &[String],
        focused_command: Option<&str>,
        pane_count: usize,
    ) -> String {
        match kind {
            WorkspaceTemplateKind::Bookmark => {
                Self::suggest_bookmark_name(title, pane_working_directories)
            }
            WorkspaceTemplateKind::Preset => Self::suggest_preset_name(focused_command, pane_count),
        }
    }

    fn suggest_bookmark_name(title: Option<&str>, pane_working_directories: &[String]) -> String {
        if let Some(title) = title.and_then(trimmed_non_empty) {
            return title.to_string();
        }
        if let Some(root) =
            WorkspaceTemplateCapture::longest_common_ancestor(pane_working_directories)
            && let Some(name) = path_last_component(&root)
        {
            return name;
        }
        if let Some(first) = pane_working_directories.first()
            && let Some(name) = path_last_component(first)
        {
            return name;
        }
        "Untitled bookmark".to_string()
    }

    fn suggest_preset_name(focused_command: Option<&str>, pane_count: usize) -> String {
        if let Some(command) = focused_command.and_then(trimmed_non_empty)
            && !is_shell_process_name(command)
        {
            let pane_label = if pane_count == 1 { "pane" } else { "panes" };
            return format!("{pane_count} {pane_label}: {command}");
        }
        format!("{pane_count}-pane preset")
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceTemplateBundle {
    pub schema_version: i32,
    pub saved_at: String,
    pub templates: Vec<WorkspaceTemplate>,
}

impl WorkspaceTemplateBundle {
    pub const CURRENT_SCHEMA_VERSION: i32 = 1;

    pub fn new(templates: Vec<WorkspaceTemplate>) -> Self {
        Self {
            schema_version: Self::CURRENT_SCHEMA_VERSION,
            saved_at: now_iso8601(),
            templates,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceTemplateExportEnvelope {
    pub schema_version: i32,
    pub exported_at: String,
    pub template: WorkspaceTemplate,
}

impl WorkspaceTemplateExportEnvelope {
    pub const CURRENT_SCHEMA_VERSION: i32 = 1;
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkspaceTemplateImportError {
    Decode(String),
    SchemaVersionTooNew { found: i32, supported: i32 },
}

impl fmt::Display for WorkspaceTemplateImportError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Decode(error) => write!(formatter, "Failed to decode preset: {error}"),
            Self::SchemaVersionTooNew { found, supported } => write!(
                formatter,
                "This preset was created by a newer version of Zentty (schema {found}, supported up to {supported})."
            ),
        }
    }
}

impl Error for WorkspaceTemplateImportError {}

pub struct WorkspaceTemplateExporter;

impl WorkspaceTemplateExporter {
    pub const FILE_EXTENSION: &'static str = "zenttypreset";

    pub fn export(template: &WorkspaceTemplate) -> io::Result<Vec<u8>> {
        let envelope = WorkspaceTemplateExportEnvelope {
            schema_version: WorkspaceTemplateExportEnvelope::CURRENT_SCHEMA_VERSION,
            exported_at: now_iso8601(),
            template: preset_copy(template).stripping_unsafe_environment(),
        };
        serde_json::to_vec_pretty(&envelope).map_err(io::Error::other)
    }

    pub fn write(template: &WorkspaceTemplate, path: &Path) -> io::Result<()> {
        if let Some(parent) = path.parent()
            && !parent.as_os_str().is_empty()
        {
            fs::create_dir_all(parent)?;
        }
        let data = Self::export(template)?;
        let temp_path = path.with_extension(format!("{}.tmp", Self::FILE_EXTENSION));
        fs::write(&temp_path, data)?;
        if path.exists() {
            fs::remove_file(path)?;
        }
        fs::rename(temp_path, path)
    }

    pub fn read(path: &Path) -> io::Result<WorkspaceTemplate> {
        let data = fs::read(path)?;
        Self::import_template(&data)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
    }

    pub fn import_template(data: &[u8]) -> Result<WorkspaceTemplate, WorkspaceTemplateImportError> {
        let envelope: WorkspaceTemplateExportEnvelope = serde_json::from_slice(data)
            .map_err(|error| WorkspaceTemplateImportError::Decode(error.to_string()))?;
        if envelope.schema_version > WorkspaceTemplateExportEnvelope::CURRENT_SCHEMA_VERSION {
            return Err(WorkspaceTemplateImportError::SchemaVersionTooNew {
                found: envelope.schema_version,
                supported: WorkspaceTemplateExportEnvelope::CURRENT_SCHEMA_VERSION,
            });
        }

        let now = now_iso8601();
        let mut template = envelope.template.stripping_unsafe_environment();
        template.id = Uuid::new_v4().to_string();
        template.created_at = now.clone();
        template.updated_at = now;
        template.last_used_at = None;
        template.pinned = false;
        Ok(template)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct BookmarksPopoverModel {
    pub bookmarks: Vec<WorkspaceTemplate>,
    pub presets: Vec<WorkspaceTemplate>,
    pub has_any_templates: bool,
}

impl BookmarksPopoverModel {
    pub fn build(templates: &[WorkspaceTemplate], query: &str) -> Self {
        let query = query.trim().to_lowercase();
        let mut filtered = templates
            .iter()
            .filter_map(|template| {
                if query.is_empty() {
                    return Some((template.clone(), 0.0));
                }
                let haystack = [
                    template.name.as_str(),
                    template.project_root.as_deref().unwrap_or(""),
                    template.title.as_deref().unwrap_or(""),
                ]
                .join(" ")
                .to_lowercase();
                let score = FuzzyMatcher::score(&query, &haystack);
                (score > 0.0).then(|| (template.clone(), score))
            })
            .collect::<Vec<_>>();

        filtered.sort_by(compare_popover_entries);

        let mut bookmarks = Vec::new();
        let mut presets = Vec::new();
        for (template, _) in filtered {
            match template.kind {
                WorkspaceTemplateKind::Bookmark => bookmarks.push(template),
                WorkspaceTemplateKind::Preset => presets.push(template),
            }
        }

        Self {
            bookmarks,
            presets,
            has_any_templates: !templates.is_empty(),
        }
    }

    pub fn is_empty_after_filtering(&self) -> bool {
        self.bookmarks.is_empty() && self.presets.is_empty()
    }
}

#[derive(Clone, Debug)]
pub struct BookmarkStore {
    path: PathBuf,
    templates: Vec<WorkspaceTemplate>,
}

impl BookmarkStore {
    pub fn load(path: PathBuf) -> io::Result<Self> {
        let templates = load_templates(&path)?;
        Ok(Self { path, templates })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn templates(&self) -> &[WorkspaceTemplate] {
        &self.templates
    }

    pub fn template(&self, id: &str) -> Option<&WorkspaceTemplate> {
        self.templates.iter().find(|template| template.id == id)
    }

    pub fn upsert(&mut self, template: WorkspaceTemplate) -> io::Result<()> {
        let mut updated = template;
        updated.updated_at = now_iso8601();
        if let Some(index) = self
            .templates
            .iter()
            .position(|template| template.id == updated.id)
        {
            self.templates[index] = updated;
        } else {
            self.templates.push(updated);
        }
        self.persist()
    }

    pub fn delete(&mut self, id: &str) -> io::Result<bool> {
        let original_len = self.templates.len();
        self.templates.retain(|template| template.id != id);
        if self.templates.len() == original_len {
            return Ok(false);
        }
        self.persist()?;
        Ok(true)
    }

    pub fn rename(&mut self, id: &str, name: &str) -> io::Result<bool> {
        let Some(trimmed) = trimmed_non_empty(name) else {
            return Ok(false);
        };
        let Some(template) = self.templates.iter_mut().find(|template| template.id == id) else {
            return Ok(false);
        };
        template.name = trimmed.to_string();
        template.updated_at = now_iso8601();
        self.persist()?;
        Ok(true)
    }

    pub fn set_pinned(&mut self, id: &str, pinned: bool) -> io::Result<bool> {
        let Some(template) = self.templates.iter_mut().find(|template| template.id == id) else {
            return Ok(false);
        };
        if template.pinned == pinned {
            return Ok(false);
        }
        template.pinned = pinned;
        template.updated_at = now_iso8601();
        self.persist()?;
        Ok(true)
    }

    pub fn record_use(&mut self, id: &str) -> io::Result<bool> {
        let Some(template) = self.templates.iter_mut().find(|template| template.id == id) else {
            return Ok(false);
        };
        template.last_used_at = Some(now_iso8601());
        self.persist()?;
        Ok(true)
    }

    pub fn duplicate(&mut self, id: &str) -> io::Result<Option<WorkspaceTemplate>> {
        let Some(original) = self.template(id).cloned() else {
            return Ok(None);
        };
        let now = now_iso8601();
        let mut copy = original.clone();
        copy.id = Uuid::new_v4().to_string();
        copy.name = self.duplicate_name_for(&original.name);
        copy.pinned = false;
        copy.created_at = now.clone();
        copy.updated_at = now;
        copy.last_used_at = None;
        self.templates.push(copy.clone());
        self.persist()?;
        Ok(Some(copy))
    }

    fn duplicate_name_for(&self, source: &str) -> String {
        let base = source.trim();
        let candidate = if base.is_empty() {
            "Copy".to_string()
        } else {
            format!("{base} copy")
        };
        let mut attempt = candidate.clone();
        let mut suffix = 2;
        while self
            .templates
            .iter()
            .any(|template| template.name == attempt)
        {
            attempt = format!("{candidate} {suffix}");
            suffix += 1;
        }
        attempt
    }

    fn persist(&self) -> io::Result<()> {
        let bundle = WorkspaceTemplateBundle::new(self.templates.clone());
        persist_bundle(&self.path, &bundle)
    }
}

pub fn template_safe_environment_overrides(
    environment: &BTreeMap<String, String>,
) -> BTreeMap<String, String> {
    environment
        .iter()
        .filter_map(|(key, value)| {
            let key = key.trim();
            if key.is_empty()
                || key.starts_with("ZENTTY_")
                || GENERATED_TEMPLATE_ENVIRONMENT_KEYS.contains(&key)
            {
                return None;
            }
            Some((key.to_string(), value.clone()))
        })
        .collect()
}

fn load_templates(path: &Path) -> io::Result<Vec<WorkspaceTemplate>> {
    if !path.exists() {
        return Ok(Vec::new());
    }

    let data = fs::read(path)?;
    match serde_json::from_slice::<WorkspaceTemplateBundle>(&data) {
        Ok(bundle) => Ok(bundle.templates),
        Err(error) => {
            preserve_corrupt_file(path, &error)?;
            Ok(Vec::new())
        }
    }
}

fn persist_bundle(path: &Path, bundle: &WorkspaceTemplateBundle) -> io::Result<()> {
    let target = symlink_target_or_self(path)?;
    if let Some(parent) = target.parent()
        && !parent.as_os_str().is_empty()
    {
        fs::create_dir_all(parent)?;
    }

    let data = serde_json::to_vec_pretty(bundle).map_err(io::Error::other)?;
    let temp_path = target.with_extension("tmp");
    fs::write(&temp_path, data)?;
    if target.exists() {
        fs::remove_file(&target)?;
    }
    fs::rename(temp_path, target)
}

fn preserve_corrupt_file(path: &Path, error: &serde_json::Error) -> io::Result<()> {
    let timestamp = now_iso8601().replace(':', "-");
    let corrupt_path = path.with_extension(format!("corrupt-{timestamp}.json"));
    fs::rename(path, &corrupt_path).map_err(|move_error| {
        io::Error::new(
            move_error.kind(),
            format!(
                "failed to read bookmarks at {} ({error}) and could not preserve corrupt file at {}: {move_error}",
                path.display(),
                corrupt_path.display()
            ),
        )
    })
}

fn symlink_target_or_self(path: &Path) -> io::Result<PathBuf> {
    match fs::read_link(path) {
        Ok(target) if target.is_absolute() => Ok(target),
        Ok(target) => Ok(path.parent().unwrap_or_else(|| Path::new("")).join(target)),
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::NotFound | io::ErrorKind::InvalidInput
            ) || error.raw_os_error() == Some(4390) =>
        {
            Ok(path.to_path_buf())
        }
        Err(error) => Err(error),
    }
}

fn preset_copy(template: &WorkspaceTemplate) -> WorkspaceTemplate {
    if template.kind == WorkspaceTemplateKind::Bookmark {
        template.stripping_working_directories()
    } else {
        template.clone()
    }
}

fn compare_popover_entries(
    lhs: &(WorkspaceTemplate, f64),
    rhs: &(WorkspaceTemplate, f64),
) -> Ordering {
    let (lhs, lhs_score) = lhs;
    let (rhs, rhs_score) = rhs;
    rhs.pinned
        .cmp(&lhs.pinned)
        .then_with(|| rhs_score.partial_cmp(lhs_score).unwrap_or(Ordering::Equal))
        .then_with(|| match (&lhs.last_used_at, &rhs.last_used_at) {
            (Some(lhs_last), Some(rhs_last)) => rhs_last.cmp(lhs_last),
            (Some(_), None) => Ordering::Less,
            (None, Some(_)) => Ordering::Greater,
            (None, None) => Ordering::Equal,
        })
        .then_with(|| lhs.name.to_lowercase().cmp(&rhs.name.to_lowercase()))
}

fn path_components_for_common_ancestor(path: &str) -> Vec<String> {
    let trimmed = path.trim().replace('/', "\\");
    let mut components = trimmed
        .split('\\')
        .filter_map(trimmed_non_empty)
        .map(str::to_string)
        .collect::<Vec<_>>();
    if components.len() == 1 && path.contains('/') {
        components = path
            .trim()
            .split('/')
            .filter_map(trimmed_non_empty)
            .map(str::to_string)
            .collect();
    }
    components
}

fn path_from_components(components: &[String]) -> String {
    if components.is_empty() {
        return String::new();
    }
    let separator = if cfg!(windows) { "\\" } else { "/" };
    if components[0].ends_with(':') {
        if components.len() == 1 {
            return format!("{}{}", components[0], separator);
        }
        return format!(
            "{}{}{}",
            components[0],
            separator,
            components[1..].join(separator)
        );
    }
    if components[0].is_empty() {
        return separator.to_string();
    }
    if cfg!(windows) {
        components.join(separator)
    } else {
        format!("/{}", components.join(separator))
    }
}

fn path_component_equal(lhs: &str, rhs: &str) -> bool {
    if cfg!(windows) {
        lhs.eq_ignore_ascii_case(rhs)
    } else {
        lhs == rhs
    }
}

fn path_last_component(path: &str) -> Option<String> {
    path_components_for_common_ancestor(path)
        .last()
        .and_then(|component| trimmed_owned(Some(component)))
}

fn is_shell_process_name(value: &str) -> bool {
    matches!(
        value.trim().to_lowercase().as_str(),
        "zsh"
            | "bash"
            | "sh"
            | "fish"
            | "dash"
            | "ksh"
            | "tcsh"
            | "csh"
            | "-zsh"
            | "-bash"
            | "-sh"
            | "-fish"
            | "-dash"
            | "-ksh"
            | "-tcsh"
            | "-csh"
            | "login"
            | "cmd"
            | "cmd.exe"
            | "powershell"
            | "powershell.exe"
            | "pwsh"
            | "pwsh.exe"
    )
}

fn now_iso8601() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
}

fn trimmed_owned(value: Option<&str>) -> Option<String> {
    value.and_then(trimmed_non_empty).map(str::to_string)
}

fn trimmed_non_empty(value: &str) -> Option<&str> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then_some(trimmed)
}
