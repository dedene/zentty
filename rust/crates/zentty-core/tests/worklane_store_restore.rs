use zentty_core::layout::{PaneColumnId, PaneColumnState, PaneId, PaneState, PaneStripState};
use zentty_core::worklane::{
    PaneCloseResult, RestoreClosedPaneResult, WorklaneState, WorklaneStore,
};

#[test]
fn user_close_pushes_entry_and_restore_replays_command_via_prefill() {
    let mut store = WorklaneStore::new(
        vec![two_column_worklane()],
        Some("wl_main".to_string()),
        "/home/user".to_string(),
    );
    store.set_current_time(100.0);

    let result = store.close_pane(&PaneId::from("pn_right"));

    assert_eq!(result, PaneCloseResult::Closed);
    assert_eq!(store.closed_pane_stack().count(), 1);
    assert_eq!(store.active_worklane().unwrap().pane_count(), 1);

    let restored = store.restore_closed_pane().expect("pane should restore");

    assert_eq!(
        restored,
        RestoreClosedPaneResult {
            restored_pane_id: PaneId::from("restored-1"),
            restored_worklane_id: "wl_main".to_string(),
            toast_message: "Restored \"right\" at C:\\Projects\\zentty".to_string(),
        }
    );
    assert_eq!(store.closed_pane_stack().count(), 0);
    assert_eq!(store.active_worklane().unwrap().pane_count(), 2);

    let restored_pane = store
        .active_worklane()
        .unwrap()
        .pane_strip_state
        .columns()
        .iter()
        .flat_map(|column| column.panes())
        .find(|pane| pane.id() == &PaneId::from("restored-1"))
        .expect("restored pane should exist");

    assert_eq!(
        restored_pane.session_request.working_directory.as_deref(),
        Some("C:\\Projects\\zentty")
    );
    assert_eq!(restored_pane.session_request.native_command, None);
    assert_eq!(restored_pane.session_request.command, None);
    assert_eq!(
        restored_pane.session_request.prefill_text.as_deref(),
        Some("npm run dev\n")
    );
}

#[test]
fn last_pane_close_signals_window_close_without_capturing_or_removing() {
    let mut store = WorklaneStore::new(
        vec![single_pane_worklane()],
        Some("wl_single".to_string()),
        "C:\\Users\\Peter".to_string(),
    );

    let pane_id = PaneId::from("pn_only");
    let result = store.close_pane(&pane_id);

    assert_eq!(result, PaneCloseResult::CloseWindow);
    assert_eq!(store.closed_pane_stack().count(), 0);
    assert_eq!(store.active_worklane().unwrap().pane_count(), 1);
    assert_eq!(
        store
            .active_worklane()
            .unwrap()
            .pane_strip_state
            .focused_pane()
            .unwrap()
            .id(),
        &pane_id
    );
}

#[test]
fn shell_exit_close_removes_without_push_to_closed_pane_stack() {
    let mut store = WorklaneStore::new(
        vec![two_column_worklane()],
        Some("wl_main".to_string()),
        "C:\\Users\\Peter".to_string(),
    );

    let result = store.close_pane_from_shell_exit(&PaneId::from("pn_right"));

    assert_eq!(result, PaneCloseResult::Closed);
    assert_eq!(store.closed_pane_stack().count(), 0);
    assert_eq!(store.active_worklane().unwrap().pane_count(), 1);
}

#[test]
fn restore_recreates_missing_column_with_original_width() {
    let mut store = WorklaneStore::new(
        vec![three_column_worklane()],
        Some("wl_main".to_string()),
        "C:\\Users\\Peter".to_string(),
    );

    assert_eq!(
        store.close_pane(&PaneId::from("pn_middle")),
        PaneCloseResult::Closed
    );
    assert_eq!(
        store
            .active_worklane()
            .unwrap()
            .pane_strip_state
            .columns()
            .len(),
        2
    );

    let result = store.restore_closed_pane().expect("pane should restore");

    let worklane = store.active_worklane().unwrap();
    assert_eq!(worklane.pane_strip_state.columns().len(), 3);
    let restored_column = worklane
        .pane_strip_state
        .columns()
        .iter()
        .find(|column| {
            column
                .panes()
                .iter()
                .any(|pane| pane.id() == &result.restored_pane_id)
        })
        .expect("restored column should exist");
    assert_eq!(restored_column.width, 800.0);
}

#[test]
fn restore_preserves_original_height_weight_within_existing_column() {
    let mut store = WorklaneStore::new(
        vec![single_column_multi_pane_worklane()],
        Some("wl_main".to_string()),
        "C:\\Users\\Peter".to_string(),
    );

    assert_eq!(
        store.close_pane(&PaneId::from("pn_middle")),
        PaneCloseResult::Closed
    );
    let result = store.restore_closed_pane().expect("pane should restore");
    let column = &store.active_worklane().unwrap().pane_strip_state.columns()[0];
    let restored_index = column
        .panes()
        .iter()
        .position(|pane| pane.id() == &result.restored_pane_id)
        .expect("restored pane should be in column");

    assert_eq!(column.pane_heights()[restored_index], 3.0);
}

#[test]
fn restore_leaves_entry_on_stack_when_no_target_worklane_exists() {
    let mut store = WorklaneStore::new(
        vec![two_column_worklane()],
        Some("wl_main".to_string()),
        "C:\\Users\\Peter".to_string(),
    );

    assert_eq!(
        store.close_pane(&PaneId::from("pn_right")),
        PaneCloseResult::Closed
    );
    assert_eq!(store.closed_pane_stack().count(), 1);

    store.replace_worklanes(Vec::new(), None);

    assert_eq!(store.restore_closed_pane(), None);
    assert_eq!(store.closed_pane_stack().count(), 1);
}

fn two_column_worklane() -> WorklaneState {
    let mut right = PaneState::new(PaneId::from("pn_right"), "right");
    right.session_request.working_directory = Some("C:\\Projects\\zentty".to_string());
    right.session_request.native_command = Some("npm run dev".to_string());

    WorklaneState::new(
        "wl_main",
        PaneStripState::new(
            vec![
                PaneColumnState::new(
                    PaneColumnId::from("col_left"),
                    vec![PaneState::new(PaneId::from("pn_left"), "left")],
                    600.0,
                    vec![1.0],
                    Some(PaneId::from("pn_left")),
                    Some(PaneId::from("pn_left")),
                ),
                PaneColumnState::new(
                    PaneColumnId::from("col_right"),
                    vec![right],
                    600.0,
                    vec![1.0],
                    Some(PaneId::from("pn_right")),
                    Some(PaneId::from("pn_right")),
                ),
            ],
            Some(PaneColumnId::from("col_right")),
        ),
    )
}

fn single_pane_worklane() -> WorklaneState {
    WorklaneState::new(
        "wl_single",
        PaneStripState::new(
            vec![PaneColumnState::new(
                PaneColumnId::from("col_only"),
                vec![PaneState::new(PaneId::from("pn_only"), "only")],
                600.0,
                vec![1.0],
                Some(PaneId::from("pn_only")),
                Some(PaneId::from("pn_only")),
            )],
            Some(PaneColumnId::from("col_only")),
        ),
    )
}

fn three_column_worklane() -> WorklaneState {
    WorklaneState::new(
        "wl_main",
        PaneStripState::new(
            vec![
                PaneColumnState::new(
                    PaneColumnId::from("col_left"),
                    vec![PaneState::new(PaneId::from("pn_left"), "left")],
                    400.0,
                    vec![1.0],
                    Some(PaneId::from("pn_left")),
                    Some(PaneId::from("pn_left")),
                ),
                PaneColumnState::new(
                    PaneColumnId::from("col_middle"),
                    vec![PaneState::new(PaneId::from("pn_middle"), "middle")],
                    800.0,
                    vec![1.0],
                    Some(PaneId::from("pn_middle")),
                    Some(PaneId::from("pn_middle")),
                ),
                PaneColumnState::new(
                    PaneColumnId::from("col_right"),
                    vec![PaneState::new(PaneId::from("pn_right"), "right")],
                    500.0,
                    vec![1.0],
                    Some(PaneId::from("pn_right")),
                    Some(PaneId::from("pn_right")),
                ),
            ],
            Some(PaneColumnId::from("col_middle")),
        ),
    )
}

fn single_column_multi_pane_worklane() -> WorklaneState {
    WorklaneState::new(
        "wl_main",
        PaneStripState::new(
            vec![PaneColumnState::new(
                PaneColumnId::from("col_main"),
                vec![
                    PaneState::new(PaneId::from("pn_top"), "top"),
                    PaneState::new(PaneId::from("pn_middle"), "middle"),
                    PaneState::new(PaneId::from("pn_bottom"), "bottom"),
                ],
                800.0,
                vec![1.0, 3.0, 1.0],
                Some(PaneId::from("pn_middle")),
                Some(PaneId::from("pn_middle")),
            )],
            Some(PaneColumnId::from("col_main")),
        ),
    )
}
