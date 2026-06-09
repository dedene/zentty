use zentty_core::layout::{
    PaneColumnId, PaneColumnState, PaneId, PanePlacement, PaneState, PaneStripState,
};

fn pane(id: &str) -> PaneState {
    PaneState::new(PaneId::from(id), id)
}

fn column(
    id: &str,
    pane_ids: &[&str],
    width: f64,
    heights: &[f64],
    focused: Option<&str>,
    last_focused: Option<&str>,
) -> PaneColumnState {
    PaneColumnState::new(
        PaneColumnId::from(id),
        pane_ids.iter().map(|id| pane(id)).collect(),
        width,
        heights.to_vec(),
        focused.map(PaneId::from),
        last_focused.map(PaneId::from),
    )
}

#[test]
fn initial_focus_defaults_to_first_column_and_pane() {
    let state = PaneStripState::new(
        vec![
            column("left", &["logs"], 500.0, &[], None, None),
            column("right", &["editor"], 500.0, &[], None, None),
        ],
        None,
    );

    assert_eq!(
        state.focused_column().map(|column| column.id()),
        Some(&PaneColumnId::from("left"))
    );
    assert_eq!(
        state.focused_pane().map(|pane| pane.id()),
        Some(&PaneId::from("logs"))
    );
}

#[test]
fn move_focus_right_restores_last_focused_pane_for_target_column() {
    let mut state = PaneStripState::new(
        vec![
            column("left", &["logs"], 500.0, &[], None, None),
            column(
                "right",
                &["build", "tests", "shell"],
                500.0,
                &[],
                Some("tests"),
                Some("tests"),
            ),
        ],
        Some(PaneColumnId::from("left")),
    );

    state.move_focus_right();

    assert_eq!(
        state.focused_column().map(|column| column.id()),
        Some(&PaneColumnId::from("right"))
    );
    assert_eq!(
        state.focused_pane().map(|pane| pane.id()),
        Some(&PaneId::from("tests"))
    );
}

#[test]
fn vertical_insert_before_focused_pane_inserts_above_and_focuses_new_pane() {
    let mut state = PaneStripState::new(
        vec![column(
            "stack",
            &["top", "middle", "bottom"],
            500.0,
            &[2.0, 6.0, 4.0],
            Some("middle"),
            Some("middle"),
        )],
        Some(PaneColumnId::from("stack")),
    );

    let inserted = state.insert_pane_vertically(
        pane("inserted"),
        Some(&PaneColumnId::from("stack")),
        PanePlacement::BeforeFocused,
        900.0,
        160.0,
    );

    assert!(inserted);
    assert_eq!(
        state.columns()[0]
            .panes()
            .iter()
            .map(|pane| pane.id().as_str())
            .collect::<Vec<_>>(),
        vec!["top", "inserted", "middle", "bottom"]
    );
    assert_eq!(
        state.focused_pane().map(|pane| pane.id()),
        Some(&PaneId::from("inserted"))
    );
    assert_eq!(state.columns()[0].pane_heights(), &[2.0, 3.0, 3.0, 4.0]);
}

#[test]
fn vertical_split_is_refused_when_equalized_height_would_violate_minimum() {
    let mut state = PaneStripState::new(
        vec![column("stack", &["top", "bottom"], 500.0, &[], None, None)],
        Some(PaneColumnId::from("stack")),
    );

    let inserted = state.insert_pane_vertically(
        pane("third"),
        Some(&PaneColumnId::from("stack")),
        PanePlacement::AfterFocused,
        420.0,
        160.0,
    );

    assert!(!inserted);
    assert_eq!(
        state.columns()[0]
            .panes()
            .iter()
            .map(|pane| pane.id().as_str())
            .collect::<Vec<_>>(),
        vec!["top", "bottom"]
    );
}

#[test]
fn move_pane_into_existing_column_equalizes_destination_stack_heights() {
    let mut state = PaneStripState::new(
        vec![
            column(
                "source",
                &["alpha", "beta"],
                320.0,
                &[2.0, 3.0],
                Some("alpha"),
                Some("alpha"),
            ),
            column(
                "target",
                &["one", "two"],
                420.0,
                &[5.0, 7.0],
                Some("one"),
                Some("one"),
            ),
        ],
        Some(PaneColumnId::from("source")),
    );

    let moved = state.move_pane(&PaneId::from("alpha"), &PaneColumnId::from("target"), 1);

    assert!(moved);
    assert_eq!(
        state.columns()[0]
            .panes()
            .iter()
            .map(|pane| pane.id().as_str())
            .collect::<Vec<_>>(),
        vec!["beta"]
    );
    assert_eq!(state.columns()[0].pane_heights(), &[5.0]);
    assert_eq!(
        state.columns()[1]
            .panes()
            .iter()
            .map(|pane| pane.id().as_str())
            .collect::<Vec<_>>(),
        vec!["one", "alpha", "two"]
    );
    assert_eq!(state.columns()[1].pane_heights(), &[1.0, 1.0, 1.0]);
    assert_eq!(
        state.focused_column().map(|column| column.id()),
        Some(&PaneColumnId::from("target"))
    );
    assert_eq!(
        state.focused_pane().map(|pane| pane.id()),
        Some(&PaneId::from("alpha"))
    );
}
