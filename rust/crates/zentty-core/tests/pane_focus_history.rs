use std::collections::HashSet;

use zentty_core::focus_history::{PaneFocusHistory, PaneReference};
use zentty_core::layout::PaneId;

fn pane_ref(worklane_id: &str, pane_id: &str) -> PaneReference {
    PaneReference::new(worklane_id, PaneId::from(pane_id))
}

fn alive(refs: &[PaneReference]) -> HashSet<PaneReference> {
    refs.iter().cloned().collect()
}

#[test]
fn record_and_navigate_back_returns_previous_pane() {
    let mut history = PaneFocusHistory::default();
    let ref_a = pane_ref("w1", "a");
    let ref_b = pane_ref("w1", "b");

    history.record(ref_a.clone());

    assert_eq!(
        history.navigate_back(ref_b, &alive(std::slice::from_ref(&ref_a))),
        Some(ref_a)
    );
}

#[test]
fn navigate_forward_after_back_returns_original() {
    let mut history = PaneFocusHistory::default();
    let ref_a = pane_ref("w1", "a");
    let ref_b = pane_ref("w1", "b");
    let live = alive(&[ref_a.clone(), ref_b.clone()]);

    history.record(ref_a.clone());

    assert_eq!(
        history.navigate_back(ref_b.clone(), &live),
        Some(ref_a.clone())
    );
    assert_eq!(history.navigate_forward(ref_a, &live), Some(ref_b));
}

#[test]
fn record_after_back_clears_forward_stack() {
    let mut history = PaneFocusHistory::default();
    let ref_a = pane_ref("w1", "a");
    let ref_b = pane_ref("w1", "b");
    let ref_c = pane_ref("w1", "c");
    let live = alive(&[ref_a.clone(), ref_b.clone(), ref_c.clone()]);

    history.record(ref_a);
    let _ = history.navigate_back(ref_b, &live);
    history.record(ref_c);

    assert!(!history.can_go_forward());
}

#[test]
fn navigate_back_and_forward_skip_closed_panes() {
    let mut history = PaneFocusHistory::default();
    let ref_a = pane_ref("w1", "a");
    let ref_b = pane_ref("w1", "b");
    let ref_c = pane_ref("w1", "c");

    history.record(ref_a.clone());
    history.record(ref_b.clone());

    assert_eq!(
        history.navigate_back(ref_c.clone(), &alive(&[ref_a.clone(), ref_c.clone()])),
        Some(ref_a.clone())
    );

    let mut history = PaneFocusHistory::default();
    history.record(ref_a.clone());
    history.record(ref_b.clone());
    let all_live = alive(&[ref_a.clone(), ref_b.clone(), ref_c.clone()]);
    let _ = history.navigate_back(ref_c.clone(), &all_live);
    let _ = history.navigate_back(ref_b, &all_live);

    assert_eq!(
        history.navigate_forward(ref_a, &alive(std::slice::from_ref(&ref_c))),
        Some(ref_c)
    );
}

#[test]
fn max_depth_trims_oldest_entries() {
    let mut history = PaneFocusHistory::new(3);
    let refs = (0..5)
        .map(|index| pane_ref("w1", &format!("pane-{index}")))
        .collect::<Vec<_>>();

    for pane_ref in &refs {
        history.record(pane_ref.clone());
    }

    assert_eq!(
        history.back_stack(),
        &[refs[2].clone(), refs[3].clone(), refs[4].clone()]
    );
}

#[test]
fn recent_references_returns_most_recent_unique_live_panes() {
    let mut history = PaneFocusHistory::default();
    let ref_a = pane_ref("w1", "a");
    let ref_b = pane_ref("w1", "b");
    let ref_c = pane_ref("w1", "c");

    history.record(ref_a.clone());
    history.record(ref_b.clone());
    history.record(ref_a.clone());
    history.record(ref_c);

    assert_eq!(
        history.recent_references(&alive(&[ref_a.clone(), ref_b.clone()])),
        vec![ref_a, ref_b]
    );
}

#[test]
fn empty_or_all_closed_stacks_return_none() {
    let mut history = PaneFocusHistory::default();
    let ref_a = pane_ref("w1", "a");
    let ref_b = pane_ref("w1", "b");
    let ref_c = pane_ref("w1", "c");

    assert_eq!(
        history.navigate_back(ref_a.clone(), &alive(std::slice::from_ref(&ref_a))),
        None
    );
    assert_eq!(
        history.navigate_forward(ref_a.clone(), &alive(std::slice::from_ref(&ref_a))),
        None
    );

    history.record(ref_a);
    history.record(ref_b);

    assert_eq!(history.navigate_back(ref_c.clone(), &alive(&[ref_c])), None);
    assert!(history.back_stack().is_empty());
}

#[test]
fn boolean_helpers_and_forward_stack_match_navigation_state() {
    let mut history = PaneFocusHistory::default();
    let ref_a = pane_ref("w1", "a");
    let ref_b = pane_ref("w1", "b");

    assert!(!history.can_go_back());
    assert!(!history.can_go_forward());

    history.record(ref_a.clone());
    assert!(history.can_go_back());
    assert!(!history.can_go_forward());

    let _ = history.navigate_back(ref_b.clone(), &alive(&[ref_a, ref_b.clone()]));

    assert!(!history.can_go_back());
    assert!(history.can_go_forward());
    assert_eq!(history.forward_stack(), &[ref_b]);
}

#[test]
fn record_does_not_deduplicate_history_entries() {
    let mut history = PaneFocusHistory::default();
    let ref_a = pane_ref("w1", "a");
    let ref_b = pane_ref("w1", "b");

    history.record(ref_a.clone());
    history.record(ref_b.clone());
    history.record(ref_a.clone());
    history.record(ref_b.clone());

    assert_eq!(
        history.back_stack(),
        &[ref_a, ref_b.clone(), pane_ref("w1", "a"), ref_b]
    );
}
