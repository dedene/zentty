use zentty_core::command_palette::{
    CommandPaletteItem, CommandPaletteItemBuilder, CommandPaletteItemFamily,
    CommandPaletteItemGroup, CommandPaletteItemId, CommandPaletteResultsResolver, DetectedServer,
    FuzzyMatcher, OpenWithBuiltInTargetId, OpenWithResolvedTarget, OpenWithTargetKind,
    RecentCommandsTracker, SearchTextNormalizer, SettingsSection, TaskRunnerAction,
    TaskRunnerDisabledReason, TaskRunnerSourceKind, WorklaneColor,
};
use zentty_core::commands::{
    AppCommandId, CommandPaletteCommandBuildContext, PaneRightCommandPresentation,
};

#[test]
fn fuzzy_matcher_scores_match_swift_basics() {
    assert_eq!(FuzzyMatcher::score("", "toggle sidebar"), 0.0);
    assert_eq!(FuzzyMatcher::score("toggle sidebar", "toggle sidebar"), 1.0);
    assert_eq!(FuzzyMatcher::score("toggle", "toggle sidebar"), 0.95);
    assert!(FuzzyMatcher::score("split", "split the focused pane horizontally") > 0.0);
    assert!(FuzzyMatcher::score("sph", "split horizontally") > 0.0);
    assert_eq!(FuzzyMatcher::score("xyz", "split horizontally"), 0.0);
    assert_eq!(FuzzyMatcher::score("a very long query", "short"), 0.0);
}

#[test]
fn fuzzy_matcher_rewards_boundaries_and_preserves_ordering() {
    let boundary_score = FuzzyMatcher::score("sh", "split horizontally");
    let no_boundary_score = FuzzyMatcher::score("sh", "ashen");
    assert!(boundary_score > no_boundary_score);

    let exact = FuzzyMatcher::score("split", "split");
    let prefix = FuzzyMatcher::score("split", "split horizontally");
    let fuzzy = FuzzyMatcher::score("sph", "split horizontally");
    assert!(exact > prefix);
    assert!(prefix > fuzzy);
}

#[test]
fn search_text_normalizer_matches_palette_rules() {
    assert_eq!(
        SearchTextNormalizer::normalized("  Open\tSettings\nNow  "),
        "open settings now"
    );
    assert_eq!(
        SearchTextNormalizer::separator_insensitive("Open-With.server/path_name"),
        "open with server path name"
    );
}

#[test]
fn recent_commands_start_empty_and_record_most_recent_first() {
    let mut tracker = RecentCommandsTracker::new();
    assert!(tracker.recent_item_ids().is_empty());

    tracker.record(CommandPaletteItemId::command("toggleSidebar"));
    tracker.record(CommandPaletteItemId::command("newWorklane"));
    tracker.record(CommandPaletteItemId::command("splitHorizontally"));

    assert_eq!(
        tracker.recent_item_ids(),
        &[
            CommandPaletteItemId::command("splitHorizontally"),
            CommandPaletteItemId::command("newWorklane"),
            CommandPaletteItemId::command("toggleSidebar"),
        ]
    );
}

#[test]
fn recent_commands_move_duplicates_to_front_and_cap_at_eight() {
    let mut tracker = RecentCommandsTracker::new();
    for id in [
        CommandPaletteItemId::command("toggleSidebar"),
        CommandPaletteItemId::command("newWorklane"),
        CommandPaletteItemId::command("nextWorklane"),
        CommandPaletteItemId::command("previousWorklane"),
        CommandPaletteItemId::command("splitHorizontally"),
        CommandPaletteItemId::command("splitVertically"),
        CommandPaletteItemId::command("closeFocusedPane"),
        CommandPaletteItemId::command("focusLeftPane"),
        CommandPaletteItemId::command("focusRightPane"),
        CommandPaletteItemId::command("toggleSidebar"),
    ] {
        tracker.record(id);
    }

    assert_eq!(tracker.recent_item_ids().len(), 8);
    assert_eq!(
        tracker.recent_item_ids().first(),
        Some(&CommandPaletteItemId::command("toggleSidebar"))
    );
    assert_eq!(
        tracker.recent_item_ids().last(),
        Some(&CommandPaletteItemId::command("nextWorklane"))
    );
}

#[test]
fn recent_commands_track_non_command_destinations() {
    let mut tracker = RecentCommandsTracker::new();
    let pane = CommandPaletteItemId::pane("worklane-1", "pane-1");

    tracker.record(CommandPaletteItemId::command("toggleSidebar"));
    tracker.record(CommandPaletteItemId::open_with("vscode"));
    tracker.record(CommandPaletteItemId::settings("appearance"));
    tracker.record(pane.clone());

    assert_eq!(
        tracker.recent_item_ids(),
        &[
            pane,
            CommandPaletteItemId::settings("appearance"),
            CommandPaletteItemId::open_with("vscode"),
            CommandPaletteItemId::command("toggleSidebar"),
        ]
    );
}

#[test]
fn empty_query_groups_curated_actions_recent_panes_and_recent_actions() {
    let new_worklane = item(CommandPaletteItemId::command("newWorklane"), "New Worklane")
        .with_search_text("new worklane");
    let split = item(
        CommandPaletteItemId::command("splitHorizontally"),
        "Split Right",
    )
    .with_search_text("split right");
    let toggle = item(
        CommandPaletteItemId::command("toggleSidebar"),
        "Toggle Sidebar",
    )
    .with_search_text("toggle sidebar");
    let current_pane = item(CommandPaletteItemId::pane("main", "current"), "Current")
        .with_group(CommandPaletteItemGroup::Pane);
    let other_pane = item(CommandPaletteItemId::pane("main", "other"), "Other")
        .with_group(CommandPaletteItemGroup::Pane);

    let resolved = CommandPaletteResultsResolver::resolve(
        "",
        vec![
            new_worklane.clone(),
            split.clone(),
            toggle.clone(),
            current_pane.clone(),
            other_pane.clone(),
        ],
        vec![toggle.clone()],
        vec![
            current_pane.id.clone(),
            other_pane.id.clone(),
            other_pane.id.clone(),
        ],
        Some(current_pane.id.clone()),
        vec![new_worklane.id.clone(), split.id.clone()],
    );

    assert_eq!(
        section_titles(&resolved),
        vec!["Actions", "Recent Panes", "Recent Actions"]
    );
    assert_eq!(
        item_ids(&resolved),
        vec![new_worklane.id, split.id, other_pane.id, toggle.id]
    );
    assert_eq!(
        resolved.sections[0]
            .items
            .iter()
            .map(|item| item.shows_subtitle)
            .collect::<Vec<_>>(),
        vec![false, false]
    );
    assert!(!resolved.requires_scrolling);
}

#[test]
fn typed_search_groups_results_by_destination_type_and_caps_each_group() {
    let pane_items = (0..20)
        .map(|index| {
            item(
                CommandPaletteItemId::pane(format!("worklane-{index}"), format!("pane-{index}")),
                format!("Palette Pane {index}"),
            )
            .with_group(CommandPaletteItemGroup::Pane)
            .with_search_text(format!("palette pane {index}"))
        })
        .collect::<Vec<_>>();
    let settings_items = (0..12)
        .map(|index| {
            item(
                CommandPaletteItemId::settings(format!("settings-{index}")),
                format!("Palette Setting {index}"),
            )
            .with_group(CommandPaletteItemGroup::Settings)
            .with_search_text(format!("palette setting {index}"))
        })
        .collect::<Vec<_>>();
    let action_items = (0..20)
        .map(|index| {
            item(
                CommandPaletteItemId::command(format!("action-{index}")),
                format!("Palette Action {index}"),
            )
            .with_group(CommandPaletteItemGroup::Action)
            .with_search_text(format!("palette action {index}"))
        })
        .collect::<Vec<_>>();
    let all_items = pane_items
        .into_iter()
        .chain(settings_items)
        .chain(action_items)
        .collect::<Vec<_>>();

    let resolved =
        CommandPaletteResultsResolver::resolve("palette", all_items, vec![], vec![], None, vec![]);

    assert_eq!(
        section_titles(&resolved),
        vec!["Panes", "Settings", "Actions"]
    );
    assert_eq!(
        resolved
            .sections
            .iter()
            .map(|section| section.items.len())
            .collect::<Vec<_>>(),
        vec![12, 8, 12]
    );
    assert!(resolved.requires_scrolling);
}

#[test]
fn title_alias_matches_rank_before_secondary_context_matches() {
    let matching_title = item(
        CommandPaletteItemId::pane("worklane-title", "pane-title"),
        "restore-closed-pane",
    )
    .with_group(CommandPaletteItemGroup::Pane)
    .with_search_text("restore-closed-pane main feature/restore-pane")
    .with_secondary_search_text("main feature/restore-pane");
    let context_only = item(
        CommandPaletteItemId::pane("worklane-context", "pane-context"),
        "unrelated-pane",
    )
    .with_group(CommandPaletteItemGroup::Pane)
    .with_search_text("unrelated-pane main restore closed pane")
    .with_secondary_search_text("main restore closed pane");

    let resolved = CommandPaletteResultsResolver::resolve(
        "restore closed pane",
        vec![context_only, matching_title.clone()],
        vec![],
        vec![],
        None,
        vec![],
    );

    assert_eq!(
        resolved.items.first().map(|item| &item.item.id),
        Some(&matching_title.id)
    );
}

#[test]
fn promotable_exact_and_prefix_matches_become_best_match() {
    let pane = item(
        CommandPaletteItemId::pane("worklane-finder", "pane-finder"),
        "finder-notes",
    )
    .with_group(CommandPaletteItemGroup::Pane)
    .with_search_text("finder-notes main finder context");
    let finder = item(CommandPaletteItemId::open_with("finder"), "Finder")
        .with_family(CommandPaletteItemFamily::OpenWith, "finder files", 0)
        .with_search_text("open with finder files");
    let cursor = item(CommandPaletteItemId::open_with("cursor"), "Cursor")
        .with_family(CommandPaletteItemFamily::OpenWith, "cursor ai editor", 1)
        .with_search_text("open with cursor ai editor");

    let exact = CommandPaletteResultsResolver::resolve(
        "finder",
        vec![pane.clone(), finder.clone(), cursor.clone()],
        vec![],
        vec![],
        None,
        vec![],
    );
    assert_eq!(
        section_titles(&exact).first().map(String::as_str),
        Some("Best Match")
    );
    assert_eq!(
        exact.items.first().map(|item| &item.item.id),
        Some(&finder.id)
    );

    let prefix = CommandPaletteResultsResolver::resolve(
        "cur",
        vec![pane, finder, cursor.clone()],
        vec![],
        vec![],
        None,
        vec![],
    );
    assert_eq!(
        prefix.items.first().map(|item| &item.item.id),
        Some(&cursor.id)
    );
}

#[test]
fn family_scoped_queries_keep_context_and_prioritize_matches() {
    let vscode = item(CommandPaletteItemId::open_with("vscode"), "VS Code")
        .with_subtitle("/tmp/project")
        .with_family(
            CommandPaletteItemFamily::OpenWith,
            "vs code visual studio code",
            0,
        )
        .with_search_text("open with vs code visual studio code");
    let finder = item(CommandPaletteItemId::open_with("finder"), "Finder")
        .with_subtitle("/tmp/project")
        .with_family(CommandPaletteItemFamily::OpenWith, "finder files", 1)
        .with_search_text("open with finder files");
    let settings = item(
        CommandPaletteItemId::command("openSettings"),
        "Open Settings",
    )
    .with_search_text("open settings preferences");

    let scoped = CommandPaletteResultsResolver::resolve(
        "open with fi",
        vec![vscode.clone(), finder.clone(), settings.clone()],
        vec![vscode.clone()],
        vec![],
        None,
        vec![],
    );
    assert_eq!(
        scoped.scope.as_ref().map(|scope| scope.family),
        Some(CommandPaletteItemFamily::OpenWith)
    );
    assert_eq!(
        scoped.scope.as_ref().map(|scope| scope.title.as_str()),
        Some("Open With")
    );
    assert_eq!(
        scoped
            .scope
            .as_ref()
            .and_then(|scope| scope.subtitle.as_deref()),
        Some("/tmp/project")
    );
    assert_eq!(
        item_ids(&scoped),
        vec![finder.id.clone(), vscode.id.clone()]
    );
    assert_eq!(
        scoped
            .items
            .iter()
            .map(|item| (item.shows_subtitle, item.shows_category))
            .collect::<Vec<_>>(),
        vec![(false, false), (false, false)]
    );

    let regular_command = CommandPaletteResultsResolver::resolve(
        "open settings",
        vec![vscode, finder, settings.clone()],
        vec![],
        vec![],
        None,
        vec![],
    );
    assert!(regular_command.scope.is_none());
    assert_eq!(
        regular_command.items.first().map(|item| &item.item.id),
        Some(&settings.id)
    );
}

#[test]
fn worklane_color_scope_surfaces_matching_color_first() {
    let blue = item(CommandPaletteItemId::worklane_color(Some("blue")), "Blue")
        .with_family(CommandPaletteItemFamily::WorklaneColor, "blue", 0)
        .with_search_text("worklane color blue");
    let red = item(CommandPaletteItemId::worklane_color(Some("red")), "Red")
        .with_family(CommandPaletteItemFamily::WorklaneColor, "red", 1)
        .with_search_text("worklane color red");
    let reset = item(
        CommandPaletteItemId::worklane_color(None::<&str>),
        "Reset to Default",
    )
    .with_family(
        CommandPaletteItemFamily::WorklaneColor,
        "reset default clear",
        2,
    )
    .with_search_text("worklane color reset default clear");

    let resolved = CommandPaletteResultsResolver::resolve(
        "worklane color red",
        vec![blue, reset, red.clone()],
        vec![],
        vec![],
        None,
        vec![],
    );

    assert_eq!(
        resolved.scope.as_ref().map(|scope| scope.family),
        Some(CommandPaletteItemFamily::WorklaneColor)
    );
    assert_eq!(
        resolved.items.first().map(|item| &item.item.id),
        Some(&red.id)
    );
}

#[test]
fn builder_generates_settings_items_for_every_section() {
    let items = CommandPaletteItemBuilder::build_settings_items();

    assert_eq!(
        items.iter().map(|item| item.id.clone()).collect::<Vec<_>>(),
        SettingsSection::ALL
            .into_iter()
            .map(|section| CommandPaletteItemId::settings(section.raw_value()))
            .collect::<Vec<_>>()
    );
    assert_eq!(
        items
            .iter()
            .map(|item| item.title.clone())
            .collect::<Vec<_>>(),
        SettingsSection::ALL
            .into_iter()
            .map(|section| format!("{} Settings", section.title()))
            .collect::<Vec<_>>()
    );
    assert!(
        items
            .iter()
            .all(|item| item.group == CommandPaletteItemGroup::Settings)
    );
    assert!(
        items
            .iter()
            .any(|item| item.icon_system_name == "cpu" && item.title == "Agents Settings")
    );
}

#[test]
fn builder_command_items_filter_available_ids_and_use_definition_metadata() {
    let items = CommandPaletteItemBuilder::build_command_items(
        &[AppCommandId::ToggleSidebar, AppCommandId::NewWorklane],
        &CommandPaletteCommandBuildContext::default()
            .with_shortcut_display(AppCommandId::ToggleSidebar, "Cmd+S"),
    );

    assert_eq!(
        items.iter().map(|item| item.id.clone()).collect::<Vec<_>>(),
        vec![
            CommandPaletteItemId::command(AppCommandId::ToggleSidebar.raw_value()),
            CommandPaletteItemId::command(AppCommandId::NewWorklane.raw_value()),
        ]
    );
    assert_eq!(
        items
            .iter()
            .map(|item| item.title.clone())
            .collect::<Vec<_>>(),
        vec!["Toggle Sidebar".to_string(), "New Worklane".to_string()]
    );
    assert_eq!(items[0].subtitle, "Show or hide the sidebar.");
    assert_eq!(items[0].shortcut_display.as_deref(), Some("Cmd+S"));
    assert_eq!(items[0].category, "General");
    assert_eq!(items[0].icon_system_name, "sidebar.left");
}

#[test]
fn builder_command_items_apply_contextual_subtitles_and_right_pane_presentation() {
    let context = CommandPaletteCommandBuildContext::default()
        .with_focused_pane_path("/Users/peter/projects")
        .with_focused_branch_name("feature/remote-link")
        .with_right_pane_command_presentation(PaneRightCommandPresentation::SplitsVisibly);
    let items = CommandPaletteItemBuilder::build_command_items(
        &[
            AppCommandId::SplitHorizontally,
            AppCommandId::CopyFocusedPanePath,
            AppCommandId::OpenBranchOnRemote,
        ],
        &context,
    );

    assert_eq!(items[0].title, "Split Right");
    assert_eq!(
        items[0].subtitle,
        "Split the current pane area into two visible panes."
    );
    assert_eq!(items[0].icon_system_name, "rectangle.split.2x1");
    assert!(
        items[0]
            .search_text
            .contains("new pane right split horizontal add pane right")
    );

    assert_eq!(
        items[1].subtitle,
        "Copy Path \u{2014} /Users/peter/projects"
    );
    assert_eq!(items[1].icon_system_name, "doc.on.doc");

    assert_eq!(items[2].title, "Open Branch on Remote");
    assert_eq!(
        items[2].subtitle,
        "Open remote branch \u{2014} feature/remote-link"
    );
    assert!(items[2].search_text.contains("remote branch"));
    assert!(items[2].search_text.contains("github branch"));
}

#[test]
fn builder_command_items_keep_unbound_commands_without_shortcut_and_theme_icons() {
    let items = CommandPaletteItemBuilder::build_command_items(
        &[
            AppCommandId::DuplicateFocusedPane,
            AppCommandId::ToggleLightDarkTheme,
            AppCommandId::UseDarkTheme,
            AppCommandId::UseLightTheme,
            AppCommandId::UseAutoTheme,
        ],
        &CommandPaletteCommandBuildContext::default(),
    );

    assert_eq!(items[0].title, "Duplicate This Pane");
    assert_eq!(items[0].shortcut_display, None);
    assert_eq!(
        items[1..]
            .iter()
            .map(|item| item.title.clone())
            .collect::<Vec<_>>(),
        vec![
            "Toggle Light/Dark Theme".to_string(),
            "Use Dark Theme".to_string(),
            "Use Light Theme".to_string(),
            "Use Auto Theme".to_string(),
        ]
    );
    assert!(
        items[1..]
            .iter()
            .all(|item| item.icon_system_name == "circle.lefthalf.filled")
    );
    assert!(
        items[1..]
            .iter()
            .all(|item| item.shortcut_display.is_none())
    );
}

#[test]
fn builder_restored_command_item_uses_command_as_subtitle_and_search_text() {
    let restored = CommandPaletteItemBuilder::build_restored_command_item(
        "shell",
        "pnpm start:staging\nnpm run smoke",
    );

    assert_eq!(restored.id, CommandPaletteItemId::restored_command("shell"));
    assert_eq!(restored.title, "Run Last Command Again");
    assert_eq!(restored.subtitle, "pnpm start:staging\nnpm run smoke");
    assert!(restored.search_text.contains("npm run smoke"));
    assert_eq!(restored.group, CommandPaletteItemGroup::Action);
    assert_eq!(restored.ranking_boost, 0.2);

    let results = CommandPaletteResultsResolver::resolve(
        "",
        vec![
            item(CommandPaletteItemId::command("newWorklane"), "New Worklane"),
            restored.clone(),
        ],
        vec![],
        vec![],
        None,
        vec![
            restored.id.clone(),
            CommandPaletteItemId::command("newWorklane"),
        ],
    );
    assert_eq!(
        results.items.first().map(|item| &item.item.id),
        Some(&restored.id)
    );
}

#[test]
fn builder_task_runner_items_keep_disabled_tasks_visible_and_searchable() {
    let enabled = TaskRunnerAction::new(
        "package|/repo/package.json|dev",
        "dev",
        None,
        TaskRunnerSourceKind::PackageScript,
        "/repo/package.json",
        "pnpm run dev",
        None,
    );
    let disabled = TaskRunnerAction::new(
        "taskfile|/repo/Taskfile.yml|deploy",
        "deploy",
        None,
        TaskRunnerSourceKind::Taskfile,
        "/repo/Taskfile.yml",
        "task deploy",
        Some(TaskRunnerDisabledReason::unsupported(
            "Task requires variables: TARGET",
        )),
    );

    let items =
        CommandPaletteItemBuilder::build_task_runner_items(&[enabled.clone(), disabled.clone()]);
    assert_eq!(
        items.iter().map(|item| item.id.clone()).collect::<Vec<_>>(),
        vec![
            CommandPaletteItemId::task_runner(enabled.id),
            CommandPaletteItemId::task_runner(disabled.id),
        ]
    );
    assert_eq!(
        items
            .iter()
            .map(|item| item.title.clone())
            .collect::<Vec<_>>(),
        vec!["Run task: dev".to_string(), "Run task: deploy".to_string()]
    );
    assert!(items[0].is_enabled);
    assert!(!items[1].is_enabled);
    assert_eq!(items[1].category, "Task disabled");
    assert_eq!(items[1].icon_system_name, "exclamationmark.triangle");

    let resolved = CommandPaletteResultsResolver::resolve(
        "deploy target",
        items,
        vec![],
        vec![],
        None,
        vec![],
    );
    assert_eq!(
        resolved.items.first().map(|item| &item.item.id),
        Some(&CommandPaletteItemId::task_runner(
            "taskfile|/repo/Taskfile.yml|deploy"
        ))
    );
}

#[test]
fn builder_worklane_color_items_include_reset_and_scope_through_resolver() {
    let items = CommandPaletteItemBuilder::build_worklane_color_items();

    assert_eq!(items.len(), WorklaneColor::ALL.len() + 1);
    assert!(
        items
            .iter()
            .all(|item| item.family == Some(CommandPaletteItemFamily::WorklaneColor))
    );
    assert_eq!(
        items.last().map(|item| &item.id),
        Some(&CommandPaletteItemId::worklane_color(None::<&str>))
    );

    let results = CommandPaletteResultsResolver::resolve(
        "worklane color red",
        items,
        vec![],
        vec![],
        None,
        vec![],
    );
    assert_eq!(
        results.scope.as_ref().map(|scope| scope.family),
        Some(CommandPaletteItemFamily::WorklaneColor)
    );
    assert_eq!(
        results.items.first().map(|item| &item.item.id),
        Some(&CommandPaletteItemId::worklane_color(Some("red")))
    );
}

#[test]
fn builder_open_with_items_require_path_and_include_aliases() {
    let targets = vec![
        OpenWithResolvedTarget::new(
            "vscode",
            OpenWithTargetKind::Editor,
            "VS Code",
            Some(OpenWithBuiltInTargetId::VsCode),
            None,
        ),
        OpenWithResolvedTarget::new(
            "finder",
            OpenWithTargetKind::FileManager,
            "Finder",
            Some(OpenWithBuiltInTargetId::Finder),
            None,
        ),
    ];

    assert!(CommandPaletteItemBuilder::build_open_with_items(&targets, None).is_empty());

    let items = CommandPaletteItemBuilder::build_open_with_items(&targets, Some("/tmp/project"));
    assert_eq!(items.len(), 2);
    assert_eq!(items[0].id, CommandPaletteItemId::open_with("vscode"));
    assert_eq!(items[0].subtitle, "/tmp/project");
    assert_eq!(items[0].category, "Open With");
    assert_eq!(items[0].family, Some(CommandPaletteItemFamily::OpenWith));
    assert!(
        items[0]
            .family_search_text
            .as_deref()
            .unwrap_or_default()
            .contains("visual studio code")
    );
    assert_eq!(items[1].icon_system_name, "folder");

    let resolved =
        CommandPaletteResultsResolver::resolve("open fi", items, vec![], vec![], None, vec![]);
    assert_eq!(
        resolved.scope.as_ref().map(|scope| scope.family),
        Some(CommandPaletteItemFamily::OpenWith)
    );
    assert_eq!(
        resolved.items.first().map(|item| &item.item.id),
        Some(&CommandPaletteItemId::open_with("finder"))
    );
}

#[test]
fn builder_server_items_are_scoped_and_searchable() {
    let server = DetectedServer::new(
        "server-1",
        "http://localhost:4567",
        "http://localhost:4567/",
        "localhost:4567",
    );

    let items = CommandPaletteItemBuilder::build_server_items(&[server]);
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].id, CommandPaletteItemId::server("server-1"));
    assert_eq!(items[0].title, "Open localhost:4567");
    assert_eq!(items[0].subtitle, "http://localhost:4567/");
    assert_eq!(items[0].category, "Web Server");
    assert_eq!(items[0].icon_system_name, "globe");
    assert_eq!(items[0].family, Some(CommandPaletteItemFamily::Server));

    let resolved = CommandPaletteResultsResolver::resolve(
        "open server 4567",
        items,
        vec![],
        vec![],
        None,
        vec![],
    );
    assert_eq!(
        resolved.scope.as_ref().map(|scope| scope.family),
        Some(CommandPaletteItemFamily::Server)
    );
    assert_eq!(
        resolved.items.first().map(|item| &item.item.id),
        Some(&CommandPaletteItemId::server("server-1"))
    );
}

fn item(id: CommandPaletteItemId, title: impl Into<String>) -> CommandPaletteItem {
    CommandPaletteItem::new(id, title, "", "Actions", "")
}

fn section_titles(
    resolved: &zentty_core::command_palette::CommandPaletteResolvedResults,
) -> Vec<String> {
    resolved
        .sections
        .iter()
        .map(|section| section.title.clone())
        .collect()
}

fn item_ids(
    resolved: &zentty_core::command_palette::CommandPaletteResolvedResults,
) -> Vec<CommandPaletteItemId> {
    resolved
        .items
        .iter()
        .map(|item| item.item.id.clone())
        .collect()
}
