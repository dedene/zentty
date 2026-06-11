use zentty_core::commands::{
    AppCommandId, CommandAvailabilityContext, CommandAvailabilityResolver,
};

#[test]
fn single_pane_hides_pane_navigation_but_keeps_close_available() {
    let available = available(CommandAvailabilityContext::new(1, 1, 1));

    assert!(available.contains(&AppCommandId::CloseFocusedPane));
    assert!(!available.contains(&AppCommandId::FocusLeftPane));
    assert!(!available.contains(&AppCommandId::FocusRightPane));
    assert!(!available.contains(&AppCommandId::FocusPreviousPane));
    assert!(!available.contains(&AppCommandId::FocusNextPane));
    assert!(!available.contains(&AppCommandId::ResizePaneLeft));
    assert!(!available.contains(&AppCommandId::ResetPaneLayout));
}

#[test]
fn multiple_panes_enable_pane_navigation_resize_and_reset() {
    let available = available(CommandAvailabilityContext::new(1, 3, 3));

    assert!(available.contains(&AppCommandId::CloseFocusedPane));
    assert!(available.contains(&AppCommandId::FocusLeftPane));
    assert!(available.contains(&AppCommandId::FocusPreviousPane));
    assert!(available.contains(&AppCommandId::FocusNextPane));
    assert!(available.contains(&AppCommandId::ResizePaneLeft));
    assert!(available.contains(&AppCommandId::ResetPaneLayout));
}

#[test]
fn arrangement_presets_follow_column_and_pane_counts() {
    let two_column = available(CommandAvailabilityContext::new(1, 2, 2).with_layout_counts(2, 1));
    assert!(two_column.contains(&AppCommandId::ArrangeWidthFull));
    assert!(two_column.contains(&AppCommandId::ArrangeWidthHalves));
    assert!(!two_column.contains(&AppCommandId::ArrangeWidthThirds));
    assert!(!two_column.contains(&AppCommandId::ArrangeWidthQuarters));
    assert!(two_column.contains(&AppCommandId::ArrangeHeightFull));
    assert!(two_column.contains(&AppCommandId::ArrangeHeightTwoPerColumn));
    assert!(!two_column.contains(&AppCommandId::ArrangeHeightThreePerColumn));
    assert!(!two_column.contains(&AppCommandId::ArrangeHeightFourPerColumn));

    let three_column = available(CommandAvailabilityContext::new(1, 3, 3).with_layout_counts(3, 3));
    assert!(three_column.contains(&AppCommandId::ArrangeWidthThirds));
    assert!(!three_column.contains(&AppCommandId::ArrangeWidthQuarters));
    assert!(three_column.contains(&AppCommandId::ArrangeHeightThreePerColumn));
    assert!(!three_column.contains(&AppCommandId::ArrangeHeightFourPerColumn));

    let vertical_stack =
        available(CommandAvailabilityContext::new(1, 4, 4).with_layout_counts(1, 4));
    assert!(!vertical_stack.contains(&AppCommandId::ArrangeWidthHalves));
    assert!(!vertical_stack.contains(&AppCommandId::ArrangeWidthThirds));
    assert!(!vertical_stack.contains(&AppCommandId::ArrangeWidthQuarters));
    assert!(vertical_stack.contains(&AppCommandId::ArrangeHeightTwoPerColumn));
    assert!(vertical_stack.contains(&AppCommandId::ArrangeHeightThreePerColumn));
    assert!(vertical_stack.contains(&AppCommandId::ArrangeHeightFourPerColumn));
}

#[test]
fn worklane_and_search_navigation_match_swift_policy() {
    let single = available(CommandAvailabilityContext::new(1, 1, 1));
    assert!(single.contains(&AppCommandId::NextWorklane));
    assert!(single.contains(&AppCommandId::PreviousWorklane));
    assert!(!single.contains(&AppCommandId::FindNext));
    assert!(!single.contains(&AppCommandId::FindPrevious));

    let remembered_global_search =
        available(CommandAvailabilityContext::new(1, 1, 1).with_global_search_memory(true));
    assert!(remembered_global_search.contains(&AppCommandId::FindNext));
    assert!(remembered_global_search.contains(&AppCommandId::FindPrevious));

    let multiple_worklanes = available(CommandAvailabilityContext::new(3, 1, 3));
    assert!(multiple_worklanes.contains(&AppCommandId::FocusPreviousPane));
    assert!(multiple_worklanes.contains(&AppCommandId::FocusNextPane));
    assert!(multiple_worklanes.contains(&AppCommandId::WorklaneMoveUp));
    assert!(multiple_worklanes.contains(&AppCommandId::WorklaneMoveDown));
}

#[test]
fn command_palette_is_hidden_but_general_commands_are_available() {
    let available = available(CommandAvailabilityContext::new(1, 1, 1));

    assert!(!available.contains(&AppCommandId::ShowCommandPalette));
    assert!(available.contains(&AppCommandId::ToggleSidebar));
    assert!(available.contains(&AppCommandId::OpenSettings));
    assert!(available.contains(&AppCommandId::ReloadConfig));
    assert!(available.contains(&AppCommandId::NewWorklane));
}

#[test]
fn context_gated_open_actions_require_matching_context() {
    let unavailable = available(CommandAvailabilityContext::new(1, 1, 1));
    assert!(!unavailable.contains(&AppCommandId::OpenWithSelectedApp));
    assert!(!unavailable.contains(&AppCommandId::OpenSelectedServer));
    assert!(!unavailable.contains(&AppCommandId::OpenBranchOnRemote));

    let available = available(
        CommandAvailabilityContext::new(1, 1, 1)
            .with_focused_pane_can_open_with_primary(true)
            .with_active_worklane_primary_server(true)
            .with_active_worklane_branch_url(true),
    );
    assert!(available.contains(&AppCommandId::OpenWithSelectedApp));
    assert!(available.contains(&AppCommandId::OpenSelectedServer));
    assert!(available.contains(&AppCommandId::OpenBranchOnRemote));
}

#[test]
fn raw_command_ids_match_swift_values_for_menu_and_config_compatibility() {
    assert_eq!(AppCommandId::ToggleSidebar.raw_value(), "sidebar.toggle");
    assert_eq!(
        AppCommandId::ShowCommandPalette.raw_value(),
        "command_palette.show"
    );
    assert_eq!(
        AppCommandId::OpenWithSelectedApp.raw_value(),
        "open_with.selected_app"
    );
    assert_eq!(
        AppCommandId::OpenSelectedServer.raw_value(),
        "server.open_selected"
    );
    assert_eq!(
        AppCommandId::OpenBranchOnRemote.raw_value(),
        "branch.open_remote"
    );
}

#[test]
fn available_command_ids_in_registry_order_match_swift_palette_order() {
    let ids = CommandAvailabilityResolver::available_command_ids_in_registry_order(
        CommandAvailabilityContext::new(2, 2, 2)
            .with_layout_counts(2, 1)
            .with_focused_pane_can_open_with_primary(true)
            .with_active_worklane_primary_server(true)
            .with_active_worklane_branch_url(true),
    );

    assert!(!ids.contains(&AppCommandId::ShowCommandPalette));
    assert_eq!(
        &ids[0..5],
        &[
            AppCommandId::ToggleSidebar,
            AppCommandId::NavigateBack,
            AppCommandId::NavigateForward,
            AppCommandId::NewWorklane,
            AppCommandId::RenameCurrentWorklane,
        ]
    );

    assert!(
        position(&ids, AppCommandId::CopyFocusedPanePath)
            < position(&ids, AppCommandId::SplitHorizontally)
    );
    assert!(
        position(&ids, AppCommandId::OpenBranchOnRemote)
            < position(&ids, AppCommandId::ToggleLightDarkTheme)
    );
}

fn available(context: CommandAvailabilityContext) -> std::collections::HashSet<AppCommandId> {
    CommandAvailabilityResolver::available_command_ids(context)
}

fn position(ids: &[AppCommandId], command_id: AppCommandId) -> usize {
    ids.iter()
        .position(|id| *id == command_id)
        .expect("command id should be available")
}
