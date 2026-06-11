use zentty_terminal::{
    screen::{TerminalScreen, TerminalSearchMatch, TerminalSearchOptions},
    search::{TerminalSearchEvent, TerminalSearchSession, TerminalSearchState},
};

#[test]
fn search_session_show_and_hide_search_hud_without_forgetting_query() {
    let mut screen = TerminalScreen::new(8, 1);
    screen.feed(b"foo");
    let mut session = TerminalSearchSession::new();

    assert_eq!(
        session.show_search(),
        vec![TerminalSearchEvent::Started { needle: None }]
    );
    assert!(session.state().is_hud_visible);

    session.update_query(&screen, "foo");
    session.hide_search();

    assert_eq!(session.state().needle, "foo");
    assert!(session.state().has_remembered_search);
    assert!(!session.state().is_hud_visible);

    assert_eq!(
        session.show_search(),
        vec![TerminalSearchEvent::Started {
            needle: Some("foo".to_string())
        }]
    );
    assert!(session.state().is_hud_visible);
}

#[test]
fn search_session_updates_query_and_reports_matches() {
    let mut screen = TerminalScreen::new(12, 2);
    screen.feed(b"alpha foo\r\nBeta FOO\r\nvisible foo");
    let mut session = TerminalSearchSession::new();

    assert_eq!(
        session.update_query(&screen, "foo"),
        vec![
            TerminalSearchEvent::Started {
                needle: Some("foo".to_string())
            },
            TerminalSearchEvent::Total(2),
            TerminalSearchEvent::Selected(None),
        ]
    );

    assert_eq!(
        session.state(),
        &TerminalSearchState {
            needle: "foo".to_string(),
            selected: None,
            total: 2,
            has_remembered_search: true,
            is_hud_visible: true,
        }
    );
    assert_eq!(
        session.matches(),
        &[
            TerminalSearchMatch {
                line_index: 0,
                start_column: 6,
                end_column: 9,
            },
            TerminalSearchMatch {
                line_index: 2,
                start_column: 8,
                end_column: 11,
            },
        ]
    );
}

#[test]
fn search_session_can_search_case_insensitively() {
    let mut screen = TerminalScreen::new(10, 2);
    screen.feed(b"foo\r\nFOO");
    let mut session = TerminalSearchSession::with_options(TerminalSearchOptions {
        case_sensitive: false,
    });

    session.update_query(&screen, "foo");

    assert_eq!(session.state().total, 2);
}

#[test]
fn search_session_navigates_next_and_previous_with_wraparound() {
    let mut screen = TerminalScreen::new(8, 2);
    screen.feed(b"foo\r\nbar foo\r\nfoo end");
    let mut session = TerminalSearchSession::new();
    session.update_query(&screen, "foo");

    assert_eq!(
        session.find_next(),
        vec![TerminalSearchEvent::Selected(Some(0))]
    );
    assert_eq!(
        session.current_match(),
        Some(&TerminalSearchMatch {
            line_index: 0,
            start_column: 0,
            end_column: 3,
        })
    );
    assert_eq!(
        session.find_next(),
        vec![TerminalSearchEvent::Selected(Some(1))]
    );
    assert_eq!(
        session.find_next(),
        vec![TerminalSearchEvent::Selected(Some(2))]
    );
    assert_eq!(
        session.find_next(),
        vec![TerminalSearchEvent::Selected(Some(0))]
    );
    assert_eq!(
        session.find_previous(),
        vec![TerminalSearchEvent::Selected(Some(2))]
    );
}

#[test]
fn search_session_previous_from_unselected_uses_last_match() {
    let mut screen = TerminalScreen::new(8, 2);
    screen.feed(b"one\r\nfoo\r\nlast foo");
    let mut session = TerminalSearchSession::new();
    session.update_query(&screen, "foo");

    assert_eq!(
        session.find_previous(),
        vec![TerminalSearchEvent::Selected(Some(1))]
    );
}

#[test]
fn search_session_refresh_recomputes_matches_and_clamps_selection() {
    let mut screen = TerminalScreen::new(10, 2);
    screen.feed(b"foo one\r\nfoo two");
    let mut session = TerminalSearchSession::new();
    session.update_query(&screen, "foo");
    session.find_next();
    session.find_next();

    let mut changed_screen = TerminalScreen::new(10, 2);
    changed_screen.feed(b"only foo");

    assert_eq!(
        session.refresh_matches(&changed_screen),
        vec![
            TerminalSearchEvent::Total(1),
            TerminalSearchEvent::Selected(Some(0)),
        ]
    );
    assert_eq!(session.state().total, 1);
    assert_eq!(session.state().selected, Some(0));
}

#[test]
fn search_session_empty_query_clears_matches_but_keeps_hud_visible() {
    let mut screen = TerminalScreen::new(8, 1);
    screen.feed(b"foo");
    let mut session = TerminalSearchSession::new();
    session.update_query(&screen, "foo");

    assert_eq!(
        session.update_query(&screen, ""),
        vec![
            TerminalSearchEvent::Started { needle: None },
            TerminalSearchEvent::Total(0),
            TerminalSearchEvent::Selected(None),
        ]
    );
    assert_eq!(
        session.state(),
        &TerminalSearchState {
            needle: String::new(),
            selected: None,
            total: 0,
            has_remembered_search: true,
            is_hud_visible: true,
        }
    );
    assert!(session.matches().is_empty());
}

#[test]
fn search_session_end_resets_state_and_emits_end_event() {
    let mut screen = TerminalScreen::new(8, 1);
    screen.feed(b"foo");
    let mut session = TerminalSearchSession::new();
    session.update_query(&screen, "foo");
    session.find_next();

    assert_eq!(session.end_search(), vec![TerminalSearchEvent::Ended]);
    assert_eq!(session.state(), &TerminalSearchState::default());
    assert!(session.matches().is_empty());
    assert_eq!(session.find_next(), Vec::<TerminalSearchEvent>::new());
}
