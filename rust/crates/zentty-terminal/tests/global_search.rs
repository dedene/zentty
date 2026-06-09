use zentty_terminal::{
    global_search::{
        GlobalSearchAction, GlobalSearchCoordinator, GlobalSearchState, GlobalSearchTarget,
    },
    search::TerminalSearchEvent,
};

#[test]
fn global_search_update_query_fans_out_and_aggregates_totals() {
    let mut coordinator = GlobalSearchCoordinator::new(vec![
        target("worklane-1", "pane-1"),
        target("worklane-2", "pane-2"),
    ]);

    assert_eq!(
        coordinator.update_query("build"),
        vec![
            GlobalSearchAction::EndAllLocalSearches,
            GlobalSearchAction::BeginPaneSearch {
                pane_id: "pane-1".to_string(),
            },
            GlobalSearchAction::UpdatePaneSearch {
                pane_id: "pane-1".to_string(),
                needle: "build".to_string(),
            },
            GlobalSearchAction::BeginPaneSearch {
                pane_id: "pane-2".to_string(),
            },
            GlobalSearchAction::UpdatePaneSearch {
                pane_id: "pane-2".to_string(),
                needle: "build".to_string(),
            },
        ]
    );

    assert_eq!(
        coordinator.handle_search_event("pane-1", TerminalSearchEvent::Total(2)),
        Vec::<GlobalSearchAction>::new()
    );
    coordinator.handle_search_event("pane-2", TerminalSearchEvent::Total(1));

    assert_eq!(
        coordinator.state(),
        &GlobalSearchState {
            needle: "build".to_string(),
            selected: None,
            total: 3,
            has_remembered_search: true,
            is_hud_visible: true,
        }
    );
}

#[test]
fn global_search_find_next_walks_panes_in_frozen_order() {
    let mut coordinator = GlobalSearchCoordinator::new(vec![
        target("worklane-1", "pane-1"),
        target("worklane-2", "pane-2"),
    ]);
    coordinator.update_query("build");
    coordinator.handle_search_event("pane-1", TerminalSearchEvent::Total(1));
    coordinator.handle_search_event("pane-2", TerminalSearchEvent::Total(1));

    assert_eq!(
        coordinator.find_next(),
        vec![
            GlobalSearchAction::NavigateToTarget(target("worklane-1", "pane-1")),
            GlobalSearchAction::PaneFindNext {
                pane_id: "pane-1".to_string(),
            },
        ]
    );
    assert_eq!(
        coordinator.handle_search_event("pane-1", TerminalSearchEvent::Selected(Some(0))),
        Vec::<GlobalSearchAction>::new()
    );

    assert_eq!(
        coordinator.find_next(),
        vec![
            GlobalSearchAction::ResetPaneSelection {
                pane_id: "pane-1".to_string(),
            },
            GlobalSearchAction::NavigateToTarget(target("worklane-2", "pane-2")),
            GlobalSearchAction::PaneFindNext {
                pane_id: "pane-2".to_string(),
            },
        ]
    );
    coordinator.handle_search_event("pane-2", TerminalSearchEvent::Selected(Some(0)));

    assert_eq!(coordinator.state().selected, Some(1));
}

#[test]
fn global_search_find_previous_from_unselected_uses_last_matching_pane() {
    let mut coordinator = GlobalSearchCoordinator::new(vec![
        target("worklane-1", "pane-1"),
        target("worklane-2", "pane-2"),
    ]);
    coordinator.update_query("build");
    coordinator.handle_search_event("pane-1", TerminalSearchEvent::Total(1));
    coordinator.handle_search_event("pane-2", TerminalSearchEvent::Total(2));

    assert_eq!(
        coordinator.find_previous(),
        vec![
            GlobalSearchAction::NavigateToTarget(target("worklane-2", "pane-2")),
            GlobalSearchAction::PaneFindPrevious {
                pane_id: "pane-2".to_string(),
            },
        ]
    );
    coordinator.handle_search_event("pane-2", TerminalSearchEvent::Selected(Some(1)));

    assert_eq!(coordinator.state().selected, Some(2));
}

#[test]
fn global_search_short_query_defers_until_navigation_and_waits_for_totals() {
    let mut coordinator = GlobalSearchCoordinator::new(vec![
        target("worklane-1", "pane-1"),
        target("worklane-2", "pane-2"),
    ]);

    assert_eq!(
        coordinator.update_query("ab"),
        vec![GlobalSearchAction::EndAllLocalSearches]
    );
    assert_eq!(
        coordinator.find_next(),
        vec![
            GlobalSearchAction::BeginPaneSearch {
                pane_id: "pane-1".to_string(),
            },
            GlobalSearchAction::UpdatePaneSearch {
                pane_id: "pane-1".to_string(),
                needle: "ab".to_string(),
            },
            GlobalSearchAction::BeginPaneSearch {
                pane_id: "pane-2".to_string(),
            },
            GlobalSearchAction::UpdatePaneSearch {
                pane_id: "pane-2".to_string(),
                needle: "ab".to_string(),
            },
        ]
    );

    assert_eq!(
        coordinator.handle_search_event("pane-1", TerminalSearchEvent::Total(0)),
        Vec::<GlobalSearchAction>::new()
    );
    assert_eq!(
        coordinator.handle_search_event("pane-2", TerminalSearchEvent::Total(1)),
        vec![
            GlobalSearchAction::NavigateToTarget(target("worklane-2", "pane-2")),
            GlobalSearchAction::PaneFindNext {
                pane_id: "pane-2".to_string(),
            },
        ]
    );
}

#[test]
fn global_search_end_resets_state_and_ends_frozen_panes() {
    let mut coordinator = GlobalSearchCoordinator::new(vec![
        target("worklane-1", "pane-1"),
        target("worklane-2", "pane-2"),
    ]);
    coordinator.update_query("build");
    coordinator.handle_search_event("pane-1", TerminalSearchEvent::Total(2));

    assert_eq!(
        coordinator.end(),
        vec![
            GlobalSearchAction::EndPaneSearch {
                pane_id: "pane-1".to_string(),
            },
            GlobalSearchAction::EndPaneSearch {
                pane_id: "pane-2".to_string(),
            },
        ]
    );
    assert_eq!(coordinator.state(), &GlobalSearchState::default());
}

fn target(worklane_id: &str, pane_id: &str) -> GlobalSearchTarget {
    GlobalSearchTarget {
        worklane_id: worklane_id.to_string(),
        pane_id: pane_id.to_string(),
    }
}
