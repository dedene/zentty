use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::collections::{BTreeMap, HashMap, HashSet};
use time::OffsetDateTime;

use crate::commands::{
    AppCommandDefinition, AppCommandId, AppCommandRegistry, CommandPaletteCommandBuildContext,
    PaneRightCommandPresentation,
};
use crate::server_detection::ServerUrlNormalizer;

const MAX_RECENT_COMMANDS: usize = 8;
const REQUIRES_SCROLLING_ITEM_COUNT: usize = 20;

pub struct FuzzyMatcher;

impl FuzzyMatcher {
    pub fn score(query: &str, target: &str) -> f64 {
        if query.is_empty() {
            return 0.0;
        }
        if target == query {
            return 1.0;
        }
        if target.starts_with(query) {
            return 0.95;
        }

        let query_chars: Vec<char> = query.chars().collect();
        let target_chars: Vec<char> = target.chars().collect();
        let mut query_index = 0;
        let mut previous_match_index: Option<usize> = None;
        let mut raw_score = 0.0;

        for (target_index, target_char) in target_chars.iter().enumerate() {
            if query_index >= query_chars.len() {
                break;
            }
            if *target_char != query_chars[query_index] {
                continue;
            }

            if let Some(previous_index) = previous_match_index {
                let gap = target_index - previous_index - 1;
                if gap == 0 {
                    raw_score += 3.0;
                } else {
                    raw_score -= gap as f64;
                }
            }

            if target_index == 0 || is_word_boundary(target_chars[target_index - 1]) {
                raw_score += 5.0;
            }

            raw_score += 1.0;
            previous_match_index = Some(target_index);
            query_index += 1;
        }

        if query_index != query_chars.len() {
            return 0.0;
        }

        let max_possible = query_chars.len() as f64 * 9.0;
        let normalized = raw_score.max(0.0) / max_possible;
        normalized.min(0.85)
    }
}

pub struct SearchTextNormalizer;

impl SearchTextNormalizer {
    pub fn normalized(text: &str) -> String {
        text.to_lowercase()
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
    }

    pub fn separator_insensitive(text: &str) -> String {
        let separated = text
            .to_lowercase()
            .chars()
            .map(|character| {
                if is_search_separator(character) {
                    ' '
                } else {
                    character
                }
            })
            .collect::<String>();
        Self::normalized(&separated)
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum SettingsSection {
    General,
    Appearance,
    Shortcuts,
    Notifications,
    OpenWith,
    DevServers,
    PaneLayout,
    UpdatesPrivacy,
    Agents,
}

impl SettingsSection {
    pub const ALL: [Self; 9] = [
        Self::General,
        Self::Appearance,
        Self::Shortcuts,
        Self::Notifications,
        Self::OpenWith,
        Self::DevServers,
        Self::PaneLayout,
        Self::UpdatesPrivacy,
        Self::Agents,
    ];

    pub fn raw_value(self) -> &'static str {
        match self {
            Self::General => "general",
            Self::Appearance => "appearance",
            Self::Shortcuts => "shortcuts",
            Self::Notifications => "notifications",
            Self::OpenWith => "openWith",
            Self::DevServers => "devServers",
            Self::PaneLayout => "paneLayout",
            Self::UpdatesPrivacy => "updatesPrivacy",
            Self::Agents => "agents",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::General => "General",
            Self::Appearance => "Appearance",
            Self::Shortcuts => "Shortcuts",
            Self::Notifications => "Notifications",
            Self::OpenWith => "Open With",
            Self::DevServers => "Dev Servers",
            Self::PaneLayout => "Worklanes & Panes",
            Self::UpdatesPrivacy => "Updates & Privacy",
            Self::Agents => "Agents",
        }
    }

    pub fn symbol_name(self) -> &'static str {
        match self {
            Self::General => "gearshape",
            Self::Appearance => "paintpalette",
            Self::Shortcuts => "keyboard",
            Self::Notifications => "bell.badge",
            Self::OpenWith => "square.and.arrow.up.on.square",
            Self::DevServers => "globe",
            Self::PaneLayout => "rectangle.split.3x1",
            Self::UpdatesPrivacy => "arrow.triangle.2.circlepath",
            Self::Agents => "cpu",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum WorklaneColor {
    Red,
    Orange,
    Amber,
    Yellow,
    Lime,
    Green,
    Teal,
    Cyan,
    Blue,
    Indigo,
    Purple,
    Pink,
}

impl WorklaneColor {
    pub const ALL: [Self; 12] = [
        Self::Red,
        Self::Orange,
        Self::Amber,
        Self::Yellow,
        Self::Lime,
        Self::Green,
        Self::Teal,
        Self::Cyan,
        Self::Blue,
        Self::Indigo,
        Self::Purple,
        Self::Pink,
    ];

    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Red => "red",
            Self::Orange => "orange",
            Self::Amber => "amber",
            Self::Yellow => "yellow",
            Self::Lime => "lime",
            Self::Green => "green",
            Self::Teal => "teal",
            Self::Cyan => "cyan",
            Self::Blue => "blue",
            Self::Indigo => "indigo",
            Self::Purple => "purple",
            Self::Pink => "pink",
        }
    }

    pub fn from_raw_value(raw_value: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|color| color.raw_value() == raw_value)
    }

    pub fn localized_name(self) -> &'static str {
        match self {
            Self::Red => "Red",
            Self::Orange => "Orange",
            Self::Amber => "Amber",
            Self::Yellow => "Yellow",
            Self::Lime => "Lime",
            Self::Green => "Green",
            Self::Teal => "Teal",
            Self::Cyan => "Cyan",
            Self::Blue => "Blue",
            Self::Indigo => "Indigo",
            Self::Purple => "Purple",
            Self::Pink => "Pink",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum OpenWithTargetKind {
    Editor,
    FileManager,
    Terminal,
}

impl OpenWithTargetKind {
    fn search_hint(self) -> &'static str {
        match self {
            Self::Editor => "code",
            Self::FileManager => "finder files",
            Self::Terminal => "terminal",
        }
    }

    fn icon_system_name(self) -> &'static str {
        match self {
            Self::Editor => "pencil.and.outline",
            Self::FileManager => "folder",
            Self::Terminal => "terminal",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum OpenWithBuiltInTargetId {
    VsCode,
    VsCodeInsiders,
    Cursor,
    Zed,
    Windsurf,
    Antigravity,
    Codex,
    Claude,
    Finder,
    Xcode,
    AndroidStudio,
    IntellijIdea,
    Rider,
    Goland,
    Rustrover,
    Pycharm,
    Webstorm,
    Phpstorm,
    SublimeText,
    Bbedit,
    Textmate,
}

impl OpenWithBuiltInTargetId {
    fn search_aliases(self) -> &'static str {
        match self {
            Self::VsCode => "code visual studio code visual studio",
            Self::VsCodeInsiders => "code insiders visual studio code insiders visual studio",
            Self::Cursor => "ai editor",
            Self::Zed => "zed editor",
            Self::Windsurf => "codeium ai editor",
            Self::Antigravity => "ai editor",
            Self::Codex => "openai ai editor coding agent",
            Self::Claude => "anthropic ai editor coding agent",
            Self::Finder => "files file manager",
            Self::Xcode => "apple ide swift",
            Self::AndroidStudio => "jetbrains android",
            Self::IntellijIdea => "jetbrains idea intellij",
            Self::Rider => "jetbrains dotnet",
            Self::Goland => "jetbrains go",
            Self::Rustrover => "jetbrains rust",
            Self::Pycharm => "jetbrains python",
            Self::Webstorm => "jetbrains javascript typescript",
            Self::Phpstorm => "jetbrains php",
            Self::SublimeText => "sublime",
            Self::Bbedit => "bare bones",
            Self::Textmate => "text mate",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OpenWithResolvedTarget {
    pub stable_id: String,
    pub kind: OpenWithTargetKind,
    pub display_name: String,
    pub built_in_id: Option<OpenWithBuiltInTargetId>,
    pub app_path: Option<String>,
}

impl OpenWithResolvedTarget {
    pub fn new(
        stable_id: impl Into<String>,
        kind: OpenWithTargetKind,
        display_name: impl Into<String>,
        built_in_id: Option<OpenWithBuiltInTargetId>,
        app_path: Option<&str>,
    ) -> Self {
        Self {
            stable_id: stable_id.into(),
            kind,
            display_name: display_name.into(),
            built_in_id,
            app_path: app_path.map(str::to_string),
        }
    }

    fn search_aliases(&self) -> &'static str {
        self.built_in_id
            .map(OpenWithBuiltInTargetId::search_aliases)
            .unwrap_or("")
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum TaskRunnerSourceKind {
    PackageScript,
    Taskfile,
    VscodeTask,
    Justfile,
    Makefile,
    Mise,
}

impl TaskRunnerSourceKind {
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::PackageScript => "packageScript",
            Self::Taskfile => "taskfile",
            Self::VscodeTask => "vscodeTask",
            Self::Justfile => "justfile",
            Self::Makefile => "makefile",
            Self::Mise => "mise",
        }
    }

    fn display_name(self) -> &'static str {
        match self {
            Self::PackageScript => "package.json",
            Self::Taskfile => "Taskfile",
            Self::VscodeTask => "VS Code",
            Self::Justfile => "just",
            Self::Makefile => "make",
            Self::Mise => "mise",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TaskRunnerDisabledReason {
    Unsupported(String),
}

impl TaskRunnerDisabledReason {
    pub fn unsupported(reason: impl Into<String>) -> Self {
        Self::Unsupported(reason.into())
    }

    fn display_text(&self) -> &str {
        match self {
            Self::Unsupported(reason) => reason,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TaskRunnerAction {
    pub id: String,
    pub title: String,
    pub description: Option<String>,
    pub source_kind: TaskRunnerSourceKind,
    pub source_path: String,
    pub source_root: String,
    pub working_directory: String,
    pub execution_command: String,
    pub command_preview: String,
    pub environment: BTreeMap<String, String>,
    pub disabled_reason: Option<TaskRunnerDisabledReason>,
}

impl TaskRunnerAction {
    pub fn new(
        id: impl Into<String>,
        title: impl Into<String>,
        description: Option<&str>,
        source_kind: TaskRunnerSourceKind,
        source_path: impl Into<String>,
        execution_command: impl Into<String>,
        disabled_reason: Option<TaskRunnerDisabledReason>,
    ) -> Self {
        let source_path = source_path.into();
        let source_root = path_parent(&source_path);
        let execution_command = execution_command.into();
        Self {
            id: id.into(),
            title: title.into(),
            description: description.map(str::to_string),
            source_kind,
            source_path,
            source_root: source_root.clone(),
            working_directory: source_root,
            command_preview: execution_command.clone(),
            execution_command,
            environment: BTreeMap::new(),
            disabled_reason,
        }
    }

    pub fn with_source_root(mut self, source_root: impl Into<String>) -> Self {
        self.source_root = source_root.into();
        self
    }

    pub fn with_working_directory(mut self, working_directory: impl Into<String>) -> Self {
        self.working_directory = working_directory.into();
        self
    }

    pub fn with_environment(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.environment.insert(key.into(), value.into());
        self
    }

    pub fn with_id(mut self, id: impl Into<String>) -> Self {
        self.id = id.into();
        self
    }

    pub fn is_enabled(&self) -> bool {
        self.disabled_reason.is_none()
    }

    pub fn subtitle(&self) -> String {
        let source_name = path_file_name(&self.source_path);
        let source = if source_name == self.source_kind.display_name() {
            source_name
        } else {
            format!(
                "{} \u{2022} {}",
                self.source_kind.display_name(),
                source_name
            )
        };
        let base = format!("{} \u{2022} {}", source, self.command_preview);
        match &self.disabled_reason {
            Some(reason) => format!("{} \u{2022} {}", base, reason.display_text()),
            None => base,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum DetectedServerSource {
    Manual,
    Watch,
    Docker,
    Scanner,
}

impl DetectedServerSource {
    pub fn raw_value(&self) -> &'static str {
        match self {
            Self::Manual => "manual",
            Self::Watch => "watch",
            Self::Docker => "docker",
            Self::Scanner => "scanner",
        }
    }
}

impl std::str::FromStr for DetectedServerSource {
    type Err = ();

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "manual" => Ok(Self::Manual),
            "watch" => Ok(Self::Watch),
            "docker" => Ok(Self::Docker),
            "scanner" => Ok(Self::Scanner),
            _ => Err(()),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum DetectedServerConfidence {
    Explicit,
    Pid,
    Cwd,
    Worklane,
}

impl DetectedServerConfidence {
    pub fn raw_value(&self) -> &'static str {
        match self {
            Self::Explicit => "explicit",
            Self::Pid => "pid",
            Self::Cwd => "cwd",
            Self::Worklane => "worklane",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DetectedServer {
    pub id: String,
    pub origin: String,
    pub url: String,
    pub display: String,
    pub worklane_id: String,
    pub pane_id: Option<String>,
    pub source: DetectedServerSource,
    pub ports: Vec<u16>,
    pub confidence: DetectedServerConfidence,
    pub updated_at: OffsetDateTime,
    pub first_seen_at: OffsetDateTime,
}

impl DetectedServer {
    pub fn new(
        id: impl Into<String>,
        origin: impl Into<String>,
        url: impl Into<String>,
        display: impl Into<String>,
    ) -> Self {
        let origin = origin.into();
        Self {
            id: id.into(),
            ports: detected_server_ports_from_origin(&origin),
            origin,
            url: url.into(),
            display: display.into(),
            worklane_id: String::new(),
            pane_id: None,
            source: DetectedServerSource::Watch,
            confidence: DetectedServerConfidence::Explicit,
            updated_at: OffsetDateTime::UNIX_EPOCH,
            first_seen_at: OffsetDateTime::UNIX_EPOCH,
        }
    }

    pub fn with_metadata(
        mut self,
        worklane_id: impl Into<String>,
        pane_id: Option<String>,
        source: DetectedServerSource,
        confidence: DetectedServerConfidence,
        updated_at: OffsetDateTime,
    ) -> Self {
        self.worklane_id = worklane_id.into();
        self.pane_id = pane_id;
        self.source = source;
        self.confidence = confidence;
        self.updated_at = updated_at;
        self.first_seen_at = updated_at;
        if self.ports.is_empty() {
            self.ports = detected_server_ports_from_origin(&self.origin);
        }
        self
    }

    pub fn with_first_seen_at(mut self, first_seen_at: OffsetDateTime) -> Self {
        self.first_seen_at = first_seen_at;
        self
    }
}

fn detected_server_ports_from_origin(origin: &str) -> Vec<u16> {
    ServerUrlNormalizer::normalize(origin)
        .map(|candidate| vec![candidate.port])
        .unwrap_or_default()
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub enum CommandPaletteItemFamily {
    OpenWith,
    Server,
    WorklaneColor,
}

impl CommandPaletteItemFamily {
    fn all_cases() -> [Self; 3] {
        [Self::OpenWith, Self::Server, Self::WorklaneColor]
    }

    fn scope_title(self) -> &'static str {
        match self {
            Self::OpenWith => "Open With",
            Self::Server => "Server",
            Self::WorklaneColor => "Worklane color",
        }
    }

    fn explicit_remainder(self, query: &str) -> Option<String> {
        match self {
            Self::OpenWith => remainder(query, "open with"),
            Self::Server => remainder(query, "server"),
            Self::WorklaneColor => remainder(query, "worklane color"),
        }
    }

    fn alias_remainder(self, query: &str) -> Option<String> {
        match self {
            Self::OpenWith => {
                if query == "open" {
                    None
                } else {
                    remainder(query, "open")
                }
            }
            Self::Server => remainder(query, "open server"),
            Self::WorklaneColor => remainder(query, "worklane"),
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub enum CommandPaletteItemGroup {
    Pane,
    Settings,
    Action,
}

impl CommandPaletteItemGroup {
    fn search_order() -> [Self; 3] {
        [Self::Pane, Self::Settings, Self::Action]
    }

    fn title(self) -> &'static str {
        match self {
            Self::Pane => "Panes",
            Self::Settings => "Settings",
            Self::Action => "Actions",
        }
    }

    fn active_search_limit(self) -> usize {
        match self {
            Self::Pane => 12,
            Self::Settings => 8,
            Self::Action => 12,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub enum CommandPaletteItemId {
    Command(String),
    OpenWith {
        stable_id: String,
    },
    Server {
        id: String,
    },
    TaskRunner(String),
    WorklaneColor(Option<String>),
    Settings(String),
    Pane {
        worklane_id: String,
        pane_id: String,
    },
    RestoredCommand {
        pane_id: String,
    },
}

impl CommandPaletteItemId {
    pub fn command(id: impl Into<String>) -> Self {
        Self::Command(id.into())
    }

    pub fn open_with(stable_id: impl Into<String>) -> Self {
        Self::OpenWith {
            stable_id: stable_id.into(),
        }
    }

    pub fn server(id: impl Into<String>) -> Self {
        Self::Server { id: id.into() }
    }

    pub fn task_runner(id: impl Into<String>) -> Self {
        Self::TaskRunner(id.into())
    }

    pub fn worklane_color(color: Option<impl Into<String>>) -> Self {
        Self::WorklaneColor(color.map(Into::into))
    }

    pub fn settings(section: impl Into<String>) -> Self {
        Self::Settings(section.into())
    }

    pub fn pane(worklane_id: impl Into<String>, pane_id: impl Into<String>) -> Self {
        Self::Pane {
            worklane_id: worklane_id.into(),
            pane_id: pane_id.into(),
        }
    }

    pub fn restored_command(pane_id: impl Into<String>) -> Self {
        Self::RestoredCommand {
            pane_id: pane_id.into(),
        }
    }
}

impl CommandPaletteItemId {
    fn is_promotable_best_match(&self) -> bool {
        matches!(
            self,
            Self::Command(_)
                | Self::OpenWith { .. }
                | Self::Server { .. }
                | Self::TaskRunner(_)
                | Self::RestoredCommand { .. }
        )
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct CommandPaletteItem {
    pub id: CommandPaletteItemId,
    pub title: String,
    pub subtitle: String,
    pub shortcut_display: Option<String>,
    pub category: String,
    pub search_text: String,
    pub primary_search_text: String,
    pub secondary_search_text: String,
    pub primary_alias_search_text: String,
    pub secondary_alias_search_text: String,
    pub group: CommandPaletteItemGroup,
    pub icon_system_name: String,
    pub ranking_boost: f64,
    pub family: Option<CommandPaletteItemFamily>,
    pub family_search_text: Option<String>,
    pub family_order: Option<usize>,
    pub is_enabled: bool,
}

impl CommandPaletteItem {
    pub fn new(
        id: CommandPaletteItemId,
        title: impl Into<String>,
        subtitle: impl Into<String>,
        category: impl Into<String>,
        search_text: impl Into<String>,
    ) -> Self {
        let title = title.into();
        let search_text = search_text.into();
        Self {
            id,
            title: title.clone(),
            subtitle: subtitle.into(),
            shortcut_display: None,
            category: category.into(),
            search_text: SearchTextNormalizer::normalized(&search_text),
            primary_search_text: SearchTextNormalizer::normalized(&title),
            secondary_search_text: SearchTextNormalizer::normalized(&search_text),
            primary_alias_search_text: SearchTextNormalizer::separator_insensitive(&title),
            secondary_alias_search_text: SearchTextNormalizer::separator_insensitive(&search_text),
            group: CommandPaletteItemGroup::Action,
            icon_system_name: "command".to_string(),
            ranking_boost: 0.0,
            family: None,
            family_search_text: None,
            family_order: None,
            is_enabled: true,
        }
    }

    pub fn with_subtitle(mut self, subtitle: impl Into<String>) -> Self {
        self.subtitle = subtitle.into();
        self
    }

    pub fn with_group(mut self, group: CommandPaletteItemGroup) -> Self {
        self.group = group;
        self
    }

    pub fn with_search_text(mut self, search_text: impl AsRef<str>) -> Self {
        self.search_text = SearchTextNormalizer::normalized(search_text.as_ref());
        self.secondary_search_text = self.search_text.clone();
        self.secondary_alias_search_text =
            SearchTextNormalizer::separator_insensitive(search_text.as_ref());
        self
    }

    pub fn with_primary_search_text(mut self, primary_search_text: impl AsRef<str>) -> Self {
        self.primary_search_text = SearchTextNormalizer::normalized(primary_search_text.as_ref());
        self.primary_alias_search_text =
            SearchTextNormalizer::separator_insensitive(primary_search_text.as_ref());
        self
    }

    pub fn with_secondary_search_text(mut self, secondary_search_text: impl AsRef<str>) -> Self {
        self.secondary_search_text =
            SearchTextNormalizer::normalized(secondary_search_text.as_ref());
        self.secondary_alias_search_text =
            SearchTextNormalizer::separator_insensitive(secondary_search_text.as_ref());
        self
    }

    pub fn with_ranking_boost(mut self, ranking_boost: f64) -> Self {
        self.ranking_boost = ranking_boost;
        self
    }

    pub fn with_icon_system_name(mut self, icon_system_name: impl Into<String>) -> Self {
        self.icon_system_name = icon_system_name.into();
        self
    }

    pub fn with_enabled(mut self, is_enabled: bool) -> Self {
        self.is_enabled = is_enabled;
        self
    }

    pub fn with_family(
        mut self,
        family: CommandPaletteItemFamily,
        family_search_text: impl AsRef<str>,
        family_order: usize,
    ) -> Self {
        self.family = Some(family);
        self.family_search_text = Some(SearchTextNormalizer::normalized(
            family_search_text.as_ref(),
        ));
        self.family_order = Some(family_order);
        self
    }
}

pub struct CommandPaletteItemBuilder;

impl CommandPaletteItemBuilder {
    pub fn build_command_items(
        available_command_ids: &[AppCommandId],
        context: &CommandPaletteCommandBuildContext,
    ) -> Vec<CommandPaletteItem> {
        available_command_ids
            .iter()
            .map(|command_id| {
                let definition = AppCommandRegistry::definition(*command_id);
                let title =
                    Self::command_title(definition, context.right_pane_command_presentation());
                let subtitle = Self::command_subtitle(definition, context);
                let search_text = Self::command_search_text(definition, &title, &subtitle);

                let mut item = CommandPaletteItem::new(
                    CommandPaletteItemId::command(command_id.raw_value()),
                    title,
                    subtitle,
                    definition.category.title(),
                    search_text,
                )
                .with_icon_system_name(Self::command_icon_system_name(
                    *command_id,
                    context.right_pane_command_presentation(),
                ));
                item.shortcut_display =
                    context.shortcut_display(*command_id).map(ToOwned::to_owned);
                item
            })
            .collect()
    }

    pub fn build_settings_items() -> Vec<CommandPaletteItem> {
        SettingsSection::ALL
            .into_iter()
            .map(|section| {
                let title = format!("{} Settings", section.title());
                CommandPaletteItem::new(
                    CommandPaletteItemId::settings(section.raw_value()),
                    title.clone(),
                    format!("Jump to the {} settings pane.", section.title()),
                    "Settings",
                    format!(
                        "{} {} {} settings preferences configuration",
                        title,
                        section.title(),
                        section.raw_value()
                    ),
                )
                .with_group(CommandPaletteItemGroup::Settings)
                .with_ranking_boost(0.05)
                .with_icon_system_name(section.symbol_name())
            })
            .collect()
    }

    pub fn build_restored_command_item(
        pane_id: impl Into<String>,
        command: impl Into<String>,
    ) -> CommandPaletteItem {
        let command = command.into();
        CommandPaletteItem::new(
            CommandPaletteItemId::restored_command(pane_id),
            "Run Last Command Again",
            command.clone(),
            "Pane",
            format!(
                "run last command again rerun repeat restored previous {}",
                command
            ),
        )
        .with_icon_system_name("arrow.clockwise")
        .with_ranking_boost(0.2)
    }

    pub fn build_task_runner_items(actions: &[TaskRunnerAction]) -> Vec<CommandPaletteItem> {
        actions
            .iter()
            .map(|action| {
                let category = if action.is_enabled() {
                    "Task"
                } else {
                    "Task disabled"
                };
                let mut search_parts = vec![
                    "run task task runner".to_string(),
                    action.title.clone(),
                    action.source_kind.display_name().to_string(),
                    action.execution_command.clone(),
                ];
                if let Some(description) = &action.description {
                    search_parts.push(description.clone());
                }
                let subtitle = action.subtitle();
                search_parts.push(subtitle.clone());
                if let Some(reason) = &action.disabled_reason {
                    search_parts.push(reason.display_text().to_string());
                }

                CommandPaletteItem::new(
                    CommandPaletteItemId::task_runner(action.id.clone()),
                    format!("Run task: {}", action.title),
                    subtitle,
                    category,
                    search_parts.join(" "),
                )
                .with_icon_system_name(if action.is_enabled() {
                    "play.circle"
                } else {
                    "exclamationmark.triangle"
                })
                .with_ranking_boost(0.1)
                .with_enabled(action.is_enabled())
            })
            .collect()
    }

    pub fn build_worklane_color_items() -> Vec<CommandPaletteItem> {
        let mut items = WorklaneColor::ALL
            .into_iter()
            .enumerate()
            .map(|(index, color)| {
                let name = color.localized_name();
                CommandPaletteItem::new(
                    CommandPaletteItemId::worklane_color(Some(color.raw_value())),
                    name,
                    "Set the focused worklane's sidebar color.",
                    "Worklane color",
                    format!("worklane color {}", name),
                )
                .with_icon_system_name("paintpalette")
                .with_family(CommandPaletteItemFamily::WorklaneColor, name, index)
            })
            .collect::<Vec<_>>();
        items.push(
            CommandPaletteItem::new(
                CommandPaletteItemId::worklane_color(None::<&str>),
                "Reset to Default",
                "Clear the focused worklane's sidebar color.",
                "Worklane color",
                "worklane color reset default clear",
            )
            .with_icon_system_name("paintpalette")
            .with_family(
                CommandPaletteItemFamily::WorklaneColor,
                "reset default clear",
                WorklaneColor::ALL.len(),
            ),
        );
        items
    }

    pub fn build_open_with_items(
        targets: &[OpenWithResolvedTarget],
        focused_pane_path: Option<&str>,
    ) -> Vec<CommandPaletteItem> {
        let Some(path) = focused_pane_path else {
            return Vec::new();
        };

        targets
            .iter()
            .enumerate()
            .map(|(index, target)| {
                let family_search_text = [
                    target.display_name.as_str(),
                    target.kind.search_hint(),
                    target.search_aliases(),
                ]
                .into_iter()
                .filter(|part| !part.is_empty())
                .collect::<Vec<_>>()
                .join(" ");

                CommandPaletteItem::new(
                    CommandPaletteItemId::open_with(target.stable_id.clone()),
                    target.display_name.clone(),
                    path,
                    "Open With",
                    format!("open with open {}", family_search_text),
                )
                .with_icon_system_name(target.kind.icon_system_name())
                .with_family(
                    CommandPaletteItemFamily::OpenWith,
                    family_search_text,
                    index,
                )
            })
            .collect()
    }

    pub fn build_server_items(servers: &[DetectedServer]) -> Vec<CommandPaletteItem> {
        servers
            .iter()
            .enumerate()
            .map(|(index, server)| {
                let family_search_text =
                    format!("{} {} {}", server.display, server.origin, server.url);
                CommandPaletteItem::new(
                    CommandPaletteItemId::server(server.id.clone()),
                    format!("Open {}", server.display),
                    server.url.clone(),
                    "Web Server",
                    format!("open server web browser {}", family_search_text),
                )
                .with_icon_system_name("globe")
                .with_family(
                    CommandPaletteItemFamily::Server,
                    family_search_text,
                    index,
                )
            })
            .collect()
    }

    fn command_title(
        definition: AppCommandDefinition,
        right_pane_command_presentation: PaneRightCommandPresentation,
    ) -> String {
        if definition.id == AppCommandId::SplitHorizontally {
            right_pane_command_presentation.primary_title().to_string()
        } else {
            definition.title.to_string()
        }
    }

    fn command_subtitle(
        definition: AppCommandDefinition,
        context: &CommandPaletteCommandBuildContext,
    ) -> String {
        if definition.id == AppCommandId::SplitHorizontally {
            return context
                .right_pane_command_presentation()
                .primary_detail_description()
                .to_string();
        }

        match definition.id {
            AppCommandId::CopyFocusedPanePath => context
                .focused_pane_path()
                .map(|path| format!("Copy Path \u{2014} {path}"))
                .unwrap_or_else(|| definition.detail_description.to_string()),
            AppCommandId::OpenBranchOnRemote => context
                .focused_branch_name()
                .filter(|branch_name| !branch_name.is_empty())
                .map(|branch_name| format!("Open remote branch \u{2014} {branch_name}"))
                .unwrap_or_else(|| definition.detail_description.to_string()),
            _ => definition.detail_description.to_string(),
        }
    }

    fn command_search_text(
        definition: AppCommandDefinition,
        title: &str,
        subtitle: &str,
    ) -> String {
        if definition.id == AppCommandId::SplitHorizontally {
            return format!("{title} {subtitle} new pane right split horizontal add pane right")
                .to_lowercase();
        }

        definition.search_text()
    }

    fn command_icon_system_name(
        command_id: AppCommandId,
        right_pane_command_presentation: PaneRightCommandPresentation,
    ) -> &'static str {
        match command_id {
            AppCommandId::NewWorklane => "plus.square.on.square",
            AppCommandId::SplitHorizontally => {
                right_pane_command_presentation.primary_icon_system_name()
            }
            AppCommandId::SplitVertically => "rectangle.split.1x2",
            AppCommandId::OpenSettings => "gearshape",
            AppCommandId::ToggleSidebar => "sidebar.left",
            AppCommandId::CopyFocusedPanePath => "doc.on.doc",
            AppCommandId::OpenBranchOnRemote => "arrow.up.forward.app",
            AppCommandId::ToggleLightDarkTheme
            | AppCommandId::UseDarkTheme
            | AppCommandId::UseLightTheme
            | AppCommandId::UseAutoTheme => "circle.lefthalf.filled",
            _ => "command",
        }
    }
}

#[derive(Clone, Debug)]
pub struct CommandPaletteSearchIndex {
    items: Vec<CommandPaletteSearchCandidate>,
    recent_items: Vec<CommandPaletteItem>,
    recent_pane_ids: Vec<CommandPaletteItemId>,
    current_pane_id: Option<CommandPaletteItemId>,
    empty_action_ids: Vec<CommandPaletteItemId>,
    item_by_id: HashMap<CommandPaletteItemId, CommandPaletteItem>,
    items_by_family: HashMap<CommandPaletteItemFamily, Vec<CommandPaletteSearchCandidate>>,
}

impl CommandPaletteSearchIndex {
    pub fn new(
        items: Vec<CommandPaletteItem>,
        recent_items: Vec<CommandPaletteItem>,
        recent_pane_ids: Vec<CommandPaletteItemId>,
        current_pane_id: Option<CommandPaletteItemId>,
        empty_action_ids: Vec<CommandPaletteItemId>,
    ) -> Self {
        let candidates = items
            .iter()
            .cloned()
            .enumerate()
            .map(|(index, item)| CommandPaletteSearchCandidate::new(index, item))
            .collect::<Vec<_>>();
        let item_by_id = items
            .into_iter()
            .map(|item| (item.id.clone(), item))
            .collect::<HashMap<_, _>>();
        let mut items_by_family: HashMap<
            CommandPaletteItemFamily,
            Vec<CommandPaletteSearchCandidate>,
        > = HashMap::new();
        for candidate in &candidates {
            if let Some(family) = candidate.item.family {
                items_by_family
                    .entry(family)
                    .or_default()
                    .push(candidate.clone());
            }
        }

        Self {
            items: candidates,
            recent_items,
            recent_pane_ids,
            current_pane_id,
            empty_action_ids,
            item_by_id,
            items_by_family,
        }
    }
}

#[derive(Clone, Debug)]
pub struct CommandPaletteSearchCandidate {
    index: usize,
    item: CommandPaletteItem,
    search_text: String,
    primary_search_text: String,
    secondary_search_text: String,
    primary_alias_search_text: String,
    secondary_alias_search_text: String,
    family_search_text: Option<String>,
}

impl CommandPaletteSearchCandidate {
    fn new(index: usize, item: CommandPaletteItem) -> Self {
        Self {
            index,
            search_text: item.search_text.clone(),
            primary_search_text: item.primary_search_text.clone(),
            secondary_search_text: item.secondary_search_text.clone(),
            primary_alias_search_text: item.primary_alias_search_text.clone(),
            secondary_alias_search_text: item.secondary_alias_search_text.clone(),
            family_search_text: item.family_search_text.clone(),
            item,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct CommandPaletteResolvedScope {
    pub family: CommandPaletteItemFamily,
    pub title: String,
    pub subtitle: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct CommandPaletteResolvedItem {
    pub item: CommandPaletteItem,
    pub shows_subtitle: bool,
    pub shows_category: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct CommandPaletteResolvedSection {
    pub id: String,
    pub title: String,
    pub items: Vec<CommandPaletteResolvedItem>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct CommandPaletteResolvedResults {
    pub items: Vec<CommandPaletteResolvedItem>,
    pub scope: Option<CommandPaletteResolvedScope>,
    pub sections: Vec<CommandPaletteResolvedSection>,
    pub requires_scrolling: bool,
}

pub struct CommandPaletteResultsResolver;

impl CommandPaletteResultsResolver {
    pub fn resolve(
        search_text: &str,
        items: Vec<CommandPaletteItem>,
        recent_items: Vec<CommandPaletteItem>,
        recent_pane_ids: Vec<CommandPaletteItemId>,
        current_pane_id: Option<CommandPaletteItemId>,
        empty_action_ids: Vec<CommandPaletteItemId>,
    ) -> CommandPaletteResolvedResults {
        let index = CommandPaletteSearchIndex::new(
            items,
            recent_items,
            recent_pane_ids,
            current_pane_id,
            empty_action_ids,
        );
        Self::resolve_with_index(search_text, &index)
    }

    pub fn resolve_with_index(
        search_text: &str,
        search_index: &CommandPaletteSearchIndex,
    ) -> CommandPaletteResolvedResults {
        let normalized_query = SearchTextNormalizer::normalized(search_text);
        if normalized_query.is_empty() {
            return resolve_empty_results(search_index);
        }

        if let Some((family, remainder)) = resolve_scope(&normalized_query, search_index) {
            return resolve_scoped_results(&remainder, search_index, family);
        }

        let mut scored_items = search_index
            .items
            .iter()
            .filter_map(|candidate| {
                let score = field_aware_score(&normalized_query, candidate);
                (score > 0.0).then(|| CommandPaletteScoredSearchItem {
                    item: candidate.item.clone(),
                    score,
                    index: candidate.index,
                    promoted_match: promoted_match(&normalized_query, candidate),
                })
            })
            .collect::<Vec<_>>();
        scored_items.sort_by(compare_scored_search_items);

        let exact_promoted_items = scored_items
            .iter()
            .filter(|item| item.promoted_match == Some(CommandPalettePromotedMatch::Exact))
            .map(|item| item.item.clone())
            .collect::<Vec<_>>();
        let prefix_promoted_items = scored_items
            .iter()
            .filter(|item| item.promoted_match == Some(CommandPalettePromotedMatch::Prefix))
            .map(|item| item.item.clone())
            .collect::<Vec<_>>();
        let promoted_items = if exact_promoted_items.is_empty() && prefix_promoted_items.len() == 1
        {
            prefix_promoted_items
        } else {
            exact_promoted_items
        };
        let promoted_ids = promoted_items
            .iter()
            .map(|item| item.id.clone())
            .collect::<HashSet<_>>();
        let grouped_items = scored_items
            .into_iter()
            .filter(|item| !promoted_ids.contains(&item.item.id))
            .map(|item| item.item)
            .collect::<Vec<_>>();
        let sections = promoted_sections(promoted_items)
            .into_iter()
            .chain(grouped_sections(grouped_items, true))
            .collect::<Vec<_>>();

        results_from_sections(None, sections)
    }
}

#[derive(Clone, Debug)]
struct CommandPaletteScoredSearchItem {
    item: CommandPaletteItem,
    score: f64,
    index: usize,
    promoted_match: Option<CommandPalettePromotedMatch>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CommandPalettePromotedMatch {
    Exact,
    Prefix,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct RecentCommandsTracker {
    recent_item_ids: Vec<CommandPaletteItemId>,
}

impl RecentCommandsTracker {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn recent_item_ids(&self) -> &[CommandPaletteItemId] {
        &self.recent_item_ids
    }

    pub fn record(&mut self, item_id: CommandPaletteItemId) {
        self.recent_item_ids
            .retain(|existing_id| existing_id != &item_id);
        self.recent_item_ids.insert(0, item_id);
        if self.recent_item_ids.len() > MAX_RECENT_COMMANDS {
            self.recent_item_ids.truncate(MAX_RECENT_COMMANDS);
        }
    }
}

fn is_word_boundary(character: char) -> bool {
    matches!(character, ' ' | '-' | '_' | '.' | '/')
}

fn is_search_separator(character: char) -> bool {
    character.is_whitespace() || is_word_boundary(character)
}

fn remainder(query: &str, prefix: &str) -> Option<String> {
    if query == prefix {
        return Some(String::new());
    }

    let prefixed_value = format!("{prefix} ");
    query
        .strip_prefix(&prefixed_value)
        .map(|remainder| remainder.to_string())
}

fn resolve_empty_results(
    search_index: &CommandPaletteSearchIndex,
) -> CommandPaletteResolvedResults {
    let empty_action_id_set = search_index
        .empty_action_ids
        .iter()
        .cloned()
        .collect::<HashSet<_>>();
    let mut sections = Vec::new();

    let action_items = search_index
        .empty_action_ids
        .iter()
        .filter_map(|id| search_index.item_by_id.get(id).cloned())
        .collect::<Vec<_>>();
    if !action_items.is_empty() {
        sections.push(section(
            "empty-actions",
            "Actions",
            action_items,
            false,
            true,
        ));
    }

    let pane_items = dedupe_ids(&search_index.recent_pane_ids)
        .into_iter()
        .filter(|id| Some(id) != search_index.current_pane_id.as_ref())
        .filter_map(|id| search_index.item_by_id.get(&id).cloned())
        .collect::<Vec<_>>();
    if !pane_items.is_empty() {
        sections.push(section(
            "recent-panes",
            "Recent Panes",
            pane_items,
            true,
            true,
        ));
    }

    let recent_action_items = dedupe_items_by_id(
        search_index
            .recent_items
            .iter()
            .filter(|item| item.group != CommandPaletteItemGroup::Pane)
            .filter(|item| !empty_action_id_set.contains(&item.id))
            .cloned()
            .collect(),
    );
    if !recent_action_items.is_empty() {
        sections.push(section(
            "recent-actions",
            "Recent Actions",
            recent_action_items,
            true,
            true,
        ));
    }

    results_from_sections(None, sections)
}

fn resolve_scoped_results(
    query_remainder: &str,
    search_index: &CommandPaletteSearchIndex,
    family: CommandPaletteItemFamily,
) -> CommandPaletteResolvedResults {
    let family_items = search_index
        .items_by_family
        .get(&family)
        .cloned()
        .unwrap_or_default();
    let recent_rank_by_id = search_index
        .recent_items
        .iter()
        .filter(|item| item.family == Some(family))
        .enumerate()
        .map(|(index, item)| (item.id.clone(), index))
        .collect::<HashMap<_, _>>();
    let normalized_remainder = SearchTextNormalizer::normalized(query_remainder);

    let mut scored_items = family_items
        .into_iter()
        .map(|candidate| {
            let target = candidate
                .family_search_text
                .clone()
                .unwrap_or_else(|| candidate.search_text.clone());
            let score = if normalized_remainder.is_empty() {
                0.0
            } else {
                fuzzy_search_score(&normalized_remainder, &target)
            };
            let recent_rank = recent_rank_by_id.get(&candidate.item.id).copied();
            ScopedSearchItem {
                item: candidate.item,
                index: candidate.index,
                score,
                recent_rank,
            }
        })
        .collect::<Vec<_>>();
    scored_items.sort_by(compare_scoped_search_items);

    let scope_subtitle = scored_items.first().map(|item| item.item.subtitle.clone());
    let items = scored_items
        .into_iter()
        .map(|entry| CommandPaletteResolvedItem {
            item: entry.item,
            shows_subtitle: false,
            shows_category: false,
        })
        .collect::<Vec<_>>();
    let scope = CommandPaletteResolvedScope {
        family,
        title: family.scope_title().to_string(),
        subtitle: scope_subtitle,
    };
    let sections = if items.is_empty() {
        Vec::new()
    } else {
        vec![CommandPaletteResolvedSection {
            id: "results".to_string(),
            title: String::new(),
            items: items.clone(),
        }]
    };

    CommandPaletteResolvedResults {
        requires_scrolling: requires_scrolling(items.len()),
        items,
        scope: Some(scope),
        sections,
    }
}

#[derive(Clone, Debug)]
struct ScopedSearchItem {
    item: CommandPaletteItem,
    index: usize,
    score: f64,
    recent_rank: Option<usize>,
}

fn resolve_scope(
    query: &str,
    search_index: &CommandPaletteSearchIndex,
) -> Option<(CommandPaletteItemFamily, String)> {
    for family in CommandPaletteItemFamily::all_cases() {
        let Some(family_items) = search_index.items_by_family.get(&family) else {
            continue;
        };
        if family_items.is_empty() {
            continue;
        }

        if let Some(remainder) = family.explicit_remainder(query) {
            return Some((family, remainder));
        }

        if let Some(remainder) = family.alias_remainder(query) {
            let matches_family = remainder.is_empty()
                || family_items.iter().any(|candidate| {
                    let target = candidate
                        .family_search_text
                        .as_deref()
                        .unwrap_or(candidate.search_text.as_str());
                    fuzzy_search_score(&remainder, target) > 0.0
                });
            if matches_family {
                return Some((family, remainder));
            }
        }
    }

    None
}

fn grouped_sections(
    items: Vec<CommandPaletteItem>,
    applies_active_search_limits: bool,
) -> Vec<CommandPaletteResolvedSection> {
    CommandPaletteItemGroup::search_order()
        .into_iter()
        .filter_map(|group| {
            let mut group_items = items
                .iter()
                .filter(|item| item.group == group)
                .cloned()
                .collect::<Vec<_>>();
            if applies_active_search_limits {
                group_items.truncate(group.active_search_limit());
            }
            (!group_items.is_empty()).then(|| {
                section(
                    group.title().to_lowercase(),
                    group.title(),
                    group_items,
                    true,
                    true,
                )
            })
        })
        .collect()
}

fn promoted_sections(items: Vec<CommandPaletteItem>) -> Vec<CommandPaletteResolvedSection> {
    if items.is_empty() {
        Vec::new()
    } else {
        vec![section("best-match", "Best Match", items, true, true)]
    }
}

fn section(
    id: impl Into<String>,
    title: impl Into<String>,
    items: Vec<CommandPaletteItem>,
    shows_subtitle: bool,
    shows_category: bool,
) -> CommandPaletteResolvedSection {
    CommandPaletteResolvedSection {
        id: id.into(),
        title: title.into(),
        items: items
            .into_iter()
            .map(|item| CommandPaletteResolvedItem {
                item,
                shows_subtitle,
                shows_category,
            })
            .collect(),
    }
}

fn results_from_sections(
    scope: Option<CommandPaletteResolvedScope>,
    sections: Vec<CommandPaletteResolvedSection>,
) -> CommandPaletteResolvedResults {
    let items = sections
        .iter()
        .flat_map(|section| section.items.clone())
        .collect::<Vec<_>>();
    CommandPaletteResolvedResults {
        requires_scrolling: requires_scrolling(items.len()),
        items,
        scope,
        sections,
    }
}

fn requires_scrolling(item_count: usize) -> bool {
    item_count > REQUIRES_SCROLLING_ITEM_COUNT
}

fn field_aware_score(query: &str, candidate: &CommandPaletteSearchCandidate) -> f64 {
    let alias_query = SearchTextNormalizer::separator_insensitive(query);
    let primary_alias_score = exactish_score(
        &alias_query,
        &candidate.primary_alias_search_text,
        100.0,
        94.0,
        88.0,
    );
    let primary_fuzzy_score = fuzzy_search_score(query, &candidate.primary_search_text);
    let secondary_alias_score = exactish_score(
        &alias_query,
        &candidate.secondary_alias_search_text,
        36.0,
        32.0,
        28.0,
    );
    let secondary_fuzzy_score = fuzzy_search_score(query, &candidate.secondary_search_text);

    let primary_score = if primary_alias_score > 0.0 {
        primary_alias_score
    } else if primary_fuzzy_score >= 0.7 {
        70.0 + primary_fuzzy_score
    } else if primary_fuzzy_score > 0.0 {
        12.0 + primary_fuzzy_score
    } else {
        0.0
    };
    let secondary_score = if secondary_alias_score > 0.0 {
        secondary_alias_score
    } else if secondary_fuzzy_score > 0.0 {
        secondary_fuzzy_score
    } else {
        0.0
    };
    let score = primary_score.max(secondary_score);
    if score > 0.0 {
        score + candidate.item.ranking_boost
    } else {
        0.0
    }
}

fn exactish_score(query: &str, target: &str, exact: f64, prefix: f64, contains: f64) -> f64 {
    if query.is_empty() || target.is_empty() {
        return 0.0;
    }
    if target == query {
        return exact;
    }
    if target.starts_with(query) {
        return prefix;
    }
    if target.contains(query) {
        return contains;
    }
    0.0
}

fn fuzzy_search_score(query: &str, target: &str) -> f64 {
    let score = FuzzyMatcher::score(query, target);
    if score > 0.0 {
        return score;
    }
    if ordered_subsequence_match(query, target) { 0.01 } else { 0.0 }
}

fn ordered_subsequence_match(query: &str, target: &str) -> bool {
    if query.is_empty() {
        return false;
    }
    let mut target_chars = target.chars();
    query.chars().all(|query_char| {
        target_chars
            .by_ref()
            .any(|target_char| target_char == query_char)
    })
}

fn promoted_match(
    query: &str,
    candidate: &CommandPaletteSearchCandidate,
) -> Option<CommandPalettePromotedMatch> {
    if !candidate.item.id.is_promotable_best_match() {
        return None;
    }
    let alias_query = SearchTextNormalizer::separator_insensitive(query);
    if alias_query.is_empty() {
        return None;
    }
    if candidate.primary_alias_search_text == alias_query {
        return Some(CommandPalettePromotedMatch::Exact);
    }
    if candidate
        .primary_alias_search_text
        .starts_with(&alias_query)
    {
        return Some(CommandPalettePromotedMatch::Prefix);
    }
    None
}

fn compare_scored_search_items(
    lhs: &CommandPaletteScoredSearchItem,
    rhs: &CommandPaletteScoredSearchItem,
) -> Ordering {
    rhs.score
        .partial_cmp(&lhs.score)
        .unwrap_or(Ordering::Equal)
        .then_with(|| lhs.index.cmp(&rhs.index))
}

fn compare_scoped_search_items(lhs: &ScopedSearchItem, rhs: &ScopedSearchItem) -> Ordering {
    let lhs_matches = lhs.score > 0.0;
    let rhs_matches = rhs.score > 0.0;
    match (lhs_matches, rhs_matches) {
        (true, false) => return Ordering::Less,
        (false, true) => return Ordering::Greater,
        _ => {}
    }

    if lhs_matches && rhs_matches {
        let by_score = rhs.score.partial_cmp(&lhs.score).unwrap_or(Ordering::Equal);
        if by_score != Ordering::Equal {
            return by_score;
        }
    }

    match (lhs.recent_rank, rhs.recent_rank) {
        (Some(left), Some(right)) if left != right => return left.cmp(&right),
        (Some(_), None) => return Ordering::Less,
        (None, Some(_)) => return Ordering::Greater,
        _ => {}
    }

    let lhs_family_order = lhs.item.family_order.unwrap_or(lhs.index);
    let rhs_family_order = rhs.item.family_order.unwrap_or(rhs.index);
    lhs_family_order
        .cmp(&rhs_family_order)
        .then_with(|| lhs.index.cmp(&rhs.index))
}

fn dedupe_ids(ids: &[CommandPaletteItemId]) -> Vec<CommandPaletteItemId> {
    let mut seen = HashSet::new();
    ids.iter()
        .filter(|id| seen.insert((*id).clone()))
        .cloned()
        .collect()
}

fn dedupe_items_by_id(items: Vec<CommandPaletteItem>) -> Vec<CommandPaletteItem> {
    let mut seen = HashSet::new();
    items
        .into_iter()
        .filter(|item| seen.insert(item.id.clone()))
        .collect()
}

fn path_file_name(path: &str) -> String {
    path.rsplit(['/', '\\'])
        .next()
        .filter(|name| !name.is_empty())
        .unwrap_or(path)
        .to_string()
}

fn path_parent(path: &str) -> String {
    path.rsplit_once(['/', '\\'])
        .map(|(parent, _)| parent)
        .filter(|parent| !parent.is_empty())
        .unwrap_or("")
        .to_string()
}
