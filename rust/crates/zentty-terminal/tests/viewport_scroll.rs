//! Viewport scroll-back: `view_cell` must show scrollback history at a given
//! `view_scroll` offset and match the model, with clamping at both ends.

use zentty_terminal::screen::TerminalScreen;

fn row_text(screen: &TerminalScreen, row: usize, width: usize) -> String {
    (0..width)
        .filter_map(|col| screen.view_cell(row, col))
        .map(|cell| cell.ch)
        .collect::<String>()
        .trim_end()
        .to_string()
}

#[test]
fn view_scroll_reveals_scrollback_and_matches_model() {
    let width = 8;
    let mut screen = TerminalScreen::new(width, 3);
    for i in 0..6 {
        screen.feed(format!("line{i}\r\n").as_bytes());
    }

    let scrollback_len = screen.scrollback_len();
    assert!(
        scrollback_len >= 2,
        "expected scrollback to accumulate, got {scrollback_len}"
    );
    let scrollback_lines = screen.scrollback_lines();

    // Live view: feed() snapped the viewport back to the bottom.
    assert_eq!(screen.view_scroll(), 0);

    // Scroll up by one: the top viewport row is the last scrollback line.
    screen.scroll_view_up(1);
    assert_eq!(screen.view_scroll(), 1);
    assert_eq!(
        row_text(&screen, 0, width),
        scrollback_lines[scrollback_len - 1].trim_end()
    );

    // Scroll up once more: the top row is the second-to-last scrollback line.
    screen.scroll_view_up(1);
    assert_eq!(
        row_text(&screen, 0, width),
        scrollback_lines[scrollback_len - 2].trim_end()
    );

    // Scrolling up is clamped to the scrollback length.
    screen.scroll_view_up(1000);
    assert_eq!(screen.view_scroll(), scrollback_len);

    // Scrolling back down returns to the live bottom, where the viewport equals
    // the live grid cell-for-cell.
    screen.scroll_view_down(1000);
    assert_eq!(screen.view_scroll(), 0);
    for row in 0..3 {
        for col in 0..width {
            assert_eq!(
                screen.view_cell(row, col).map(|cell| cell.ch),
                screen.cell(row, col).map(|cell| cell.ch),
            );
        }
    }
}

#[test]
fn feed_snaps_viewport_back_to_live_bottom() {
    let mut screen = TerminalScreen::new(8, 2);
    for i in 0..5 {
        screen.feed(format!("row{i}\r\n").as_bytes());
    }
    screen.scroll_view_up(2);
    assert_eq!(screen.view_scroll(), 2);
    // New output snaps back to the bottom.
    screen.feed(b"more\r\n");
    assert_eq!(screen.view_scroll(), 0);
}
