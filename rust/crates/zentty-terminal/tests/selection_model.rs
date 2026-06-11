use zentty_terminal::{
    screen::{TerminalScreen, TerminalTextPoint, TerminalTextRange},
    selection::TerminalSelection,
};

#[test]
fn selection_drag_normalizes_reversed_range_and_copies_from_screen() {
    let mut screen = TerminalScreen::new(8, 2);
    screen.feed(b"first\r\nsecond\r\nthird");
    let mut selection = TerminalSelection::new();

    selection.begin(TerminalTextPoint {
        line_index: 2,
        column: 2,
    });
    selection.extend(TerminalTextPoint {
        line_index: 0,
        column: 1,
    });

    assert_eq!(
        selection.range(),
        Some(TerminalTextRange {
            start: TerminalTextPoint {
                line_index: 0,
                column: 1,
            },
            end: TerminalTextPoint {
                line_index: 2,
                column: 2,
            },
        })
    );
    assert_eq!(
        selection.selected_text(&screen),
        Some("irst\nsecond\nth".to_string())
    );
}

#[test]
fn selection_clear_and_zero_width_ranges_have_no_selected_text() {
    let mut screen = TerminalScreen::new(8, 1);
    screen.feed(b"content");
    let mut selection = TerminalSelection::new();

    selection.begin(TerminalTextPoint {
        line_index: 0,
        column: 3,
    });

    assert_eq!(selection.range(), None);
    assert_eq!(selection.selected_text(&screen), None);

    selection.extend(TerminalTextPoint {
        line_index: 0,
        column: 7,
    });
    assert_eq!(selection.selected_text(&screen), Some("tent".to_string()));

    selection.clear();
    assert_eq!(selection.range(), None);
    assert_eq!(selection.selected_text(&screen), None);
}

#[test]
fn selection_word_at_expands_to_non_whitespace_bounds() {
    let mut screen = TerminalScreen::new(20, 1);
    screen.feed(b"cargo test --all");
    let mut selection = TerminalSelection::new();

    assert!(selection.select_word_at(
        &screen,
        TerminalTextPoint {
            line_index: 0,
            column: 8,
        }
    ));

    assert_eq!(selection.selected_text(&screen), Some("test".to_string()));
    assert_eq!(
        selection.range(),
        Some(TerminalTextRange {
            start: TerminalTextPoint {
                line_index: 0,
                column: 6,
            },
            end: TerminalTextPoint {
                line_index: 0,
                column: 10,
            },
        })
    );
}

#[test]
fn selection_word_at_whitespace_clears_and_reports_no_selection() {
    let mut screen = TerminalScreen::new(12, 1);
    screen.feed(b"one two");
    let mut selection = TerminalSelection::new();
    selection.select_word_at(
        &screen,
        TerminalTextPoint {
            line_index: 0,
            column: 1,
        },
    );

    assert!(!selection.select_word_at(
        &screen,
        TerminalTextPoint {
            line_index: 0,
            column: 3,
        }
    ));
    assert_eq!(selection.range(), None);
}

#[test]
fn selection_line_selects_trimmed_line_text() {
    let mut screen = TerminalScreen::new(12, 2);
    screen.feed(b"first\r\nsecond");
    let mut selection = TerminalSelection::new();

    assert!(selection.select_line(&screen, 1));

    assert_eq!(selection.selected_text(&screen), Some("second".to_string()));
    assert_eq!(
        selection.range(),
        Some(TerminalTextRange {
            start: TerminalTextPoint {
                line_index: 1,
                column: 0,
            },
            end: TerminalTextPoint {
                line_index: 1,
                column: 12,
            },
        })
    );
}

#[test]
fn selection_search_seed_requires_single_non_empty_line() {
    let mut screen = TerminalScreen::new(10, 2);
    screen.feed(b"alpha\r\nbeta");
    let mut selection = TerminalSelection::new();

    selection.begin(TerminalTextPoint {
        line_index: 0,
        column: 1,
    });
    selection.extend(TerminalTextPoint {
        line_index: 0,
        column: 5,
    });
    assert_eq!(selection.search_seed(&screen), Some("lpha".to_string()));

    selection.begin(TerminalTextPoint {
        line_index: 0,
        column: 1,
    });
    selection.extend(TerminalTextPoint {
        line_index: 1,
        column: 2,
    });
    assert_eq!(selection.search_seed(&screen), None);
}
