use zentty_terminal::screen::{
    TerminalColor, TerminalMouseMode, TerminalProgressReport, TerminalProgressState,
    TerminalScreen, TerminalSearchMatch, TerminalSearchOptions, TerminalTextPoint,
    TerminalTextRange,
};

#[test]
fn screen_feeds_plain_text_and_wraps_at_width() {
    let mut screen = TerminalScreen::new(5, 3);

    screen.feed(b"abcdef");

    assert_eq!(screen.visible_lines(), vec!["abcde", "f    ", "     "]);
    assert_eq!(screen.cursor_position(), (1, 1));
}

#[test]
fn screen_resize_preserves_visible_cells_and_clamps_cursor() {
    let mut screen = TerminalScreen::new(5, 2);

    screen.feed(b"abcdefg");
    screen.resize(3, 3);

    assert_eq!(screen.visible_lines(), vec!["abc", "fg ", "   "]);
    assert_eq!(screen.cursor_position(), (1, 2));

    screen.resize(6, 1);

    assert_eq!(screen.visible_lines(), vec!["abc   "]);
    assert_eq!(screen.cursor_position(), (0, 2));
}

#[test]
fn screen_handles_cr_lf_cursor_position_and_clear_line() {
    let mut screen = TerminalScreen::new(6, 3);

    screen.feed(b"first\r\nsecond\x1b[1;3HX\x1b[K");

    assert_eq!(screen.visible_lines(), vec!["fiX   ", "second", "      "]);
    assert_eq!(screen.cursor_position(), (0, 3));
}

#[test]
fn screen_tracks_osc_9_4_progress_reports() {
    let mut screen = TerminalScreen::new(5, 2);

    screen.feed(b"\x1b]9;4;3\x07");
    assert_eq!(
        screen.progress_report(),
        Some(TerminalProgressReport {
            state: TerminalProgressState::Indeterminate,
            progress: None,
        })
    );
    assert!(screen.terminal_progress_indicates_activity());

    screen.feed(b"\x1b]9;4;1;42\x1b\\");
    assert_eq!(
        screen.progress_report(),
        Some(TerminalProgressReport {
            state: TerminalProgressState::Set,
            progress: Some(42),
        })
    );
    assert!(screen.terminal_progress_indicates_activity());

    screen.feed(b"\x1b]9;4;0\x07");
    assert_eq!(
        screen.progress_report(),
        Some(TerminalProgressReport {
            state: TerminalProgressState::Remove,
            progress: None,
        })
    );
    assert!(!screen.terminal_progress_indicates_activity());
}

#[test]
fn screen_moves_cursor_to_next_tab_stop_on_tab_output() {
    let mut screen = TerminalScreen::new(16, 2);

    screen.feed(b"a\tb");

    assert_eq!(screen.visible_lines()[0], "a       b       ");
    assert_eq!(screen.cursor_position(), (0, 9));

    screen.feed(b"\tZ");

    assert_eq!(screen.visible_lines()[0], "a       b      Z");
    assert_eq!(screen.cursor_position(), (1, 0));
}

#[test]
fn screen_handles_absolute_cursor_row_and_column_sequences() {
    let mut screen = TerminalScreen::new(8, 3);

    screen.feed(b"abcd\x1b[1GZ\x1b[3dY");

    assert_eq!(
        screen.visible_lines(),
        vec!["Zbcd    ", "        ", " Y      "]
    );
    assert_eq!(screen.cursor_position(), (2, 2));
}

#[test]
fn screen_moves_cursor_to_next_and_previous_line_sequences() {
    let mut screen = TerminalScreen::new(6, 4);

    screen.feed(b"ab\x1b[2Ecd\x1b[FZ");

    assert_eq!(
        screen.visible_lines(),
        vec!["ab    ", "Z     ", "cd    ", "      "]
    );
    assert_eq!(screen.cursor_position(), (1, 1));
}

#[test]
fn screen_handles_escape_index_next_line_and_reverse_index() {
    let mut index = TerminalScreen::new(5, 2);
    index.feed(b"ab\x1bDcd");
    assert_eq!(index.visible_lines(), vec!["ab   ", "  cd "]);
    assert_eq!(index.cursor_position(), (1, 4));

    let mut next_line = TerminalScreen::new(5, 2);
    next_line.feed(b"ab\x1bEcd");
    assert_eq!(next_line.visible_lines(), vec!["ab   ", "cd   "]);
    assert_eq!(next_line.cursor_position(), (1, 2));

    let mut reverse = TerminalScreen::new(5, 2);
    reverse.feed(b"ab\x1bEcd\x1bMZ");
    assert_eq!(reverse.visible_lines(), vec!["abZ  ", "cd   "]);
    assert_eq!(reverse.cursor_position(), (0, 3));

    let mut reverse_at_top = TerminalScreen::new(5, 2);
    reverse_at_top.feed(b"111\r\n222\x1b[1;4H\x1bMZ");
    assert_eq!(reverse_at_top.visible_lines(), vec!["   Z ", "111  "]);
    assert_eq!(reverse_at_top.cursor_position(), (0, 4));
    assert_eq!(reverse_at_top.scrollback_lines(), Vec::<String>::new());
}

#[test]
fn screen_saves_and_restores_cursor_with_csi_and_escape_sequences() {
    let mut csi = TerminalScreen::new(8, 2);
    csi.feed(b"ab\x1b[sXY\x1b[uZ");
    assert_eq!(csi.visible_lines(), vec!["abZY    ", "        "]);
    assert_eq!(csi.cursor_position(), (0, 3));

    let mut escape = TerminalScreen::new(8, 2);
    escape.feed(b"ab\x1b7XY\x1b8Z");
    assert_eq!(escape.visible_lines(), vec!["abZY    ", "        "]);
    assert_eq!(escape.cursor_position(), (0, 3));
}

#[test]
fn screen_switches_to_alternate_screen_and_restores_primary_buffer() {
    let mut screen = TerminalScreen::new(6, 2);

    screen.feed(b"main");
    screen.feed(b"\x1b[?1049h");

    assert_eq!(screen.visible_lines(), vec!["      ", "      "]);
    assert_eq!(screen.cursor_position(), (0, 0));

    screen.feed(b"alt");
    assert_eq!(screen.visible_lines(), vec!["alt   ", "      "]);
    assert_eq!(screen.plain_text(), "alt");

    screen.feed(b"\x1b[?1049l");
    assert_eq!(screen.visible_lines(), vec!["main  ", "      "]);
    assert_eq!(screen.cursor_position(), (0, 4));

    screen.feed(b"!");
    assert_eq!(screen.visible_lines(), vec!["main! ", "      "]);
    assert_eq!(screen.cursor_position(), (0, 5));
}

#[test]
fn screen_keeps_alternate_screen_output_out_of_primary_scrollback() {
    let mut screen = TerminalScreen::new(6, 2);

    screen.feed(b"one\r\ntwo\r\nthree");
    assert_eq!(screen.scrollback_lines(), vec!["one   "]);
    assert_eq!(screen.visible_lines(), vec!["two   ", "three "]);

    screen.feed(b"\x1b[?1049hfull\r\nscr\r\nmore");

    assert_eq!(screen.visible_lines(), vec!["scr   ", "more  "]);
    assert_eq!(screen.scrollback_lines(), Vec::<String>::new());
    assert_eq!(screen.plain_text(), "scr\nmore");

    screen.feed(b"\x1b[?1049l");

    assert_eq!(screen.scrollback_lines(), vec!["one   "]);
    assert_eq!(screen.visible_lines(), vec!["two   ", "three "]);
}

#[test]
fn screen_tracks_bracketed_paste_private_mode() {
    let mut screen = TerminalScreen::new(6, 2);

    assert!(!screen.bracketed_paste_enabled());

    screen.feed(b"\x1b[?2004h");
    assert!(screen.bracketed_paste_enabled());

    screen.feed(b"\x1b[?2004l");
    assert!(!screen.bracketed_paste_enabled());
}

#[test]
fn screen_tracks_application_cursor_keys_private_mode() {
    let mut screen = TerminalScreen::new(6, 2);

    assert!(!screen.application_cursor_keys_enabled());

    screen.feed(b"\x1b[?1h");
    assert!(screen.application_cursor_keys_enabled());

    screen.feed(b"\x1b[?1l");
    assert!(!screen.application_cursor_keys_enabled());
}

#[test]
fn screen_tracks_cursor_visibility_private_mode() {
    let mut screen = TerminalScreen::new(6, 2);

    assert!(screen.cursor_visible());

    screen.feed(b"\x1b[?25l");
    assert!(!screen.cursor_visible());

    screen.feed(b"\x1b[?25h");
    assert!(screen.cursor_visible());
}

#[test]
fn screen_tracks_dec_mouse_reporting_modes() {
    let mut screen = TerminalScreen::new(6, 2);

    assert_eq!(screen.mouse_mode(), TerminalMouseMode::Disabled);
    assert!(!screen.sgr_mouse_enabled());

    screen.feed(b"\x1b[?1000h");
    assert_eq!(screen.mouse_mode(), TerminalMouseMode::Normal);

    screen.feed(b"\x1b[?1006h");
    assert!(screen.sgr_mouse_enabled());

    screen.feed(b"\x1b[?1002h");
    assert_eq!(screen.mouse_mode(), TerminalMouseMode::ButtonEvent);

    screen.feed(b"\x1b[?1003h");
    assert_eq!(screen.mouse_mode(), TerminalMouseMode::AnyEvent);

    screen.feed(b"\x1b[?1003l\x1b[?1006l");
    assert_eq!(screen.mouse_mode(), TerminalMouseMode::Disabled);
    assert!(!screen.sgr_mouse_enabled());
}

#[test]
fn screen_reports_cursor_position_for_device_status_request() {
    let mut screen = TerminalScreen::new(8, 3);

    screen.feed(b"abcd\x1b[2;3H\x1b[6n");

    assert_eq!(
        screen.visible_lines(),
        vec!["abcd    ", "        ", "        "]
    );
    assert_eq!(screen.cursor_position(), (1, 2));
    assert_eq!(screen.take_pending_responses(), b"\x1b[2;3R".to_vec());
    assert_eq!(screen.take_pending_responses(), Vec::<u8>::new());
}

#[test]
fn screen_reports_primary_device_attributes() {
    let mut screen = TerminalScreen::new(8, 2);

    screen.feed(b"\x1b[c\x1b[0c");

    assert_eq!(
        screen.take_pending_responses(),
        b"\x1b[?1;2c\x1b[?1;2c".to_vec()
    );
    assert_eq!(screen.visible_lines(), vec!["        ", "        "]);
}

#[test]
fn screen_clears_display_from_ansi_sequence() {
    let mut screen = TerminalScreen::new(4, 2);

    screen.feed(b"abcdwxyz\x1b[2J");

    assert_eq!(screen.visible_lines(), vec!["    ", "    "]);
    assert_eq!(screen.cursor_position(), (0, 0));
}

#[test]
fn screen_erases_display_from_cursor_and_to_cursor() {
    let mut from_cursor = TerminalScreen::new(8, 3);
    from_cursor.feed(b"aaaaaa\r\nbbbbbb\r\ncccccc\x1b[2;3H\x1b[J");

    assert_eq!(
        from_cursor.visible_lines(),
        vec!["aaaaaa  ", "bb      ", "        "]
    );
    assert_eq!(from_cursor.cursor_position(), (1, 2));

    let mut to_cursor = TerminalScreen::new(8, 3);
    to_cursor.feed(b"aaaaaa\r\nbbbbbb\r\ncccccc\x1b[2;3H\x1b[1J");

    assert_eq!(
        to_cursor.visible_lines(),
        vec!["        ", "   bbb  ", "cccccc  "]
    );
    assert_eq!(to_cursor.cursor_position(), (1, 2));
}

#[test]
fn screen_erases_line_from_cursor_to_cursor_and_entire_line() {
    let mut from_cursor = TerminalScreen::new(8, 1);
    from_cursor.feed(b"abcdef\x1b[1;4H\x1b[K");
    assert_eq!(from_cursor.visible_lines(), vec!["abc     "]);
    assert_eq!(from_cursor.cursor_position(), (0, 3));

    let mut to_cursor = TerminalScreen::new(8, 1);
    to_cursor.feed(b"abcdef\x1b[1;3H\x1b[1K");
    assert_eq!(to_cursor.visible_lines(), vec!["   def  "]);
    assert_eq!(to_cursor.cursor_position(), (0, 2));

    let mut entire_line = TerminalScreen::new(8, 1);
    entire_line.feed(b"abcdef\x1b[1;3H\x1b[2K");
    assert_eq!(entire_line.visible_lines(), vec!["        "]);
    assert_eq!(entire_line.cursor_position(), (0, 2));
}

#[test]
fn screen_inserts_and_deletes_characters_within_line() {
    let mut insert_one = TerminalScreen::new(8, 1);
    insert_one.feed(b"abcdef\x1b[1;3H\x1b[@");
    assert_eq!(insert_one.visible_lines(), vec!["ab cdef "]);
    assert_eq!(insert_one.cursor_position(), (0, 2));

    let mut insert_two = TerminalScreen::new(8, 1);
    insert_two.feed(b"abcdef\x1b[1;3H\x1b[2@");
    assert_eq!(insert_two.visible_lines(), vec!["ab  cdef"]);
    assert_eq!(insert_two.cursor_position(), (0, 2));

    let mut delete_one = TerminalScreen::new(8, 1);
    delete_one.feed(b"abcdef\x1b[1;3H\x1b[P");
    assert_eq!(delete_one.visible_lines(), vec!["abdef   "]);
    assert_eq!(delete_one.cursor_position(), (0, 2));

    let mut delete_two = TerminalScreen::new(8, 1);
    delete_two.feed(b"abcdef\x1b[1;3H\x1b[2P");
    assert_eq!(delete_two.visible_lines(), vec!["abef    "]);
    assert_eq!(delete_two.cursor_position(), (0, 2));
}

#[test]
fn screen_erases_characters_from_cursor_without_moving_cursor() {
    let mut erase_one = TerminalScreen::new(8, 1);
    erase_one.feed(b"abcdef\x1b[1;3H\x1b[X");
    assert_eq!(erase_one.visible_lines(), vec!["ab def  "]);
    assert_eq!(erase_one.cursor_position(), (0, 2));

    let mut erase_three = TerminalScreen::new(8, 1);
    erase_three.feed(b"abcdef\x1b[1;3H\x1b[3X");
    assert_eq!(erase_three.visible_lines(), vec!["ab   f  "]);
    assert_eq!(erase_three.cursor_position(), (0, 2));
}

#[test]
fn screen_inserts_and_deletes_lines_from_cursor_row() {
    let mut insert_one = TerminalScreen::new(5, 4);
    insert_one.feed(b"111\r\n222\r\n333\r\n444\x1b[2;1H\x1b[L");
    assert_eq!(
        insert_one.visible_lines(),
        vec!["111  ", "     ", "222  ", "333  "]
    );
    assert_eq!(insert_one.cursor_position(), (1, 0));

    let mut insert_two = TerminalScreen::new(5, 4);
    insert_two.feed(b"111\r\n222\r\n333\r\n444\x1b[2;1H\x1b[2L");
    assert_eq!(
        insert_two.visible_lines(),
        vec!["111  ", "     ", "     ", "222  "]
    );
    assert_eq!(insert_two.cursor_position(), (1, 0));

    let mut delete_one = TerminalScreen::new(5, 4);
    delete_one.feed(b"111\r\n222\r\n333\r\n444\x1b[2;1H\x1b[M");
    assert_eq!(
        delete_one.visible_lines(),
        vec!["111  ", "333  ", "444  ", "     "]
    );
    assert_eq!(delete_one.cursor_position(), (1, 0));

    let mut delete_two = TerminalScreen::new(5, 4);
    delete_two.feed(b"111\r\n222\r\n333\r\n444\x1b[2;1H\x1b[2M");
    assert_eq!(
        delete_two.visible_lines(),
        vec!["111  ", "444  ", "     ", "     "]
    );
    assert_eq!(delete_two.cursor_position(), (1, 0));
}

#[test]
fn screen_inserts_and_deletes_lines_only_within_vertical_margins() {
    let mut insert = TerminalScreen::new(5, 4);
    insert.feed(b"111\r\n222\r\n333\r\n444\x1b[2;3r\x1b[2;1H\x1b[L");
    assert_eq!(
        insert.visible_lines(),
        vec!["111  ", "     ", "222  ", "444  "]
    );
    assert_eq!(insert.cursor_position(), (1, 0));

    let mut delete = TerminalScreen::new(5, 4);
    delete.feed(b"111\r\n222\r\n333\r\n444\x1b[2;3r\x1b[2;1H\x1b[M");
    assert_eq!(
        delete.visible_lines(),
        vec!["111  ", "333  ", "     ", "444  "]
    );
    assert_eq!(delete.cursor_position(), (1, 0));
}

#[test]
fn screen_origin_mode_addresses_cursor_relative_to_vertical_margins() {
    let mut screen = TerminalScreen::new(5, 4);

    screen.feed(b"111\r\n222\r\n333\r\n444\x1b[2;3r\x1b[?6h");

    assert_eq!(screen.cursor_position(), (1, 0));

    screen.feed(b"\x1b[1;1HX\x1b[9;4HY");

    assert_eq!(
        screen.visible_lines(),
        vec!["111  ", "X22  ", "333Y ", "444  "]
    );
    assert_eq!(screen.cursor_position(), (2, 4));
}

#[test]
fn screen_disabling_origin_mode_restores_absolute_cursor_addressing() {
    let mut screen = TerminalScreen::new(5, 4);

    screen.feed(b"111\r\n222\r\n333\r\n444\x1b[2;3r\x1b[?6h\x1b[?6l\x1b[1;1HZ");

    assert_eq!(
        screen.visible_lines(),
        vec!["Z11  ", "222  ", "333  ", "444  "]
    );
    assert_eq!(screen.cursor_position(), (0, 1));
}

#[test]
fn screen_scrolls_visible_lines_without_changing_cursor_or_scrollback() {
    let mut scroll_up = TerminalScreen::new(5, 4);
    scroll_up.feed(b"111\r\n222\r\n333\r\n444\x1b[2S");
    assert_eq!(
        scroll_up.visible_lines(),
        vec!["333  ", "444  ", "     ", "     "]
    );
    assert_eq!(scroll_up.cursor_position(), (3, 3));
    assert_eq!(scroll_up.scrollback_lines(), Vec::<String>::new());

    let mut scroll_down = TerminalScreen::new(5, 4);
    scroll_down.feed(b"111\r\n222\r\n333\r\n444\x1b[T");
    assert_eq!(
        scroll_down.visible_lines(),
        vec!["     ", "111  ", "222  ", "333  "]
    );
    assert_eq!(scroll_down.cursor_position(), (3, 3));
    assert_eq!(scroll_down.scrollback_lines(), Vec::<String>::new());
}

#[test]
fn screen_line_feed_scrolls_only_within_vertical_margins() {
    let mut screen = TerminalScreen::new(5, 4);

    screen.feed(b"111\r\n222\r\n333\r\n444\x1b[2;3r\x1b[3;1H\n");

    assert_eq!(
        screen.visible_lines(),
        vec!["111  ", "333  ", "     ", "444  "]
    );
    assert_eq!(screen.cursor_position(), (2, 0));
    assert_eq!(screen.scrollback_lines(), Vec::<String>::new());
}

#[test]
fn screen_reverse_index_scrolls_only_within_vertical_margins() {
    let mut screen = TerminalScreen::new(5, 4);

    screen.feed(b"111\r\n222\r\n333\r\n444\x1b[2;3r\x1b[2;1H\x1bM");

    assert_eq!(
        screen.visible_lines(),
        vec!["111  ", "     ", "222  ", "444  "]
    );
    assert_eq!(screen.cursor_position(), (1, 0));
    assert_eq!(screen.scrollback_lines(), Vec::<String>::new());
}

#[test]
fn screen_records_osc_window_and_icon_titles_without_printing_them() {
    let mut screen = TerminalScreen::new(12, 2);

    screen.feed(b"before\x1b]0;Zentty OSC Title\x07after");

    assert_eq!(screen.title(), Some("Zentty OSC Title"));
    assert_eq!(screen.visible_lines()[0], "beforeafter ");

    screen.feed(b"\x1b]2;Window Title\x1b\\");
    assert_eq!(screen.title(), Some("Window Title"));

    screen.feed(b"\x1b]1;Icon Title\x07");
    assert_eq!(screen.title(), Some("Icon Title"));
}

#[test]
fn screen_resets_terminal_state_from_escape_reset() {
    let mut screen = TerminalScreen::new(6, 2);

    screen.feed(b"one\r\ntwo\r\nthree");
    screen.feed(b"\x1b[?2004h\x1b[1;31m");
    screen.feed(b"\x1b[?1049halt");

    assert_eq!(screen.visible_lines(), vec!["alt   ", "      "]);
    assert!(screen.bracketed_paste_enabled());

    screen.feed(b"\x1bcY");

    assert_eq!(screen.visible_lines(), vec!["Y     ", "      "]);
    assert_eq!(screen.scrollback_lines(), Vec::<String>::new());
    assert_eq!(screen.cursor_position(), (0, 1));
    assert!(!screen.bracketed_paste_enabled());
    assert!(screen.cursor_visible());

    let cell = screen.cell(0, 0).expect("reset cell should exist");
    assert_eq!(cell.ch, 'Y');
    assert!(!cell.bold);
    assert_eq!(cell.foreground, None);
    assert_eq!(cell.background, None);
}

#[test]
fn screen_applies_basic_sgr_attributes_to_cells() {
    let mut screen = TerminalScreen::new(8, 1);

    screen.feed(b"\x1b[1;31mR\x1b[0mN");

    let red = screen.cell(0, 0).expect("red cell should exist");
    let normal = screen.cell(0, 1).expect("normal cell should exist");

    assert_eq!(red.ch, 'R');
    assert!(red.bold);
    assert_eq!(red.foreground, Some(TerminalColor::Ansi(1)));
    assert_eq!(normal.ch, 'N');
    assert!(!normal.bold);
    assert_eq!(normal.foreground, None);
}

#[test]
fn screen_applies_bright_and_indexed_sgr_colors_to_cells() {
    let mut screen = TerminalScreen::new(8, 1);

    screen.feed(b"\x1b[93;104mB\x1b[38;5;196;48;5;236mI\x1b[0mN");

    let bright = screen.cell(0, 0).expect("bright cell should exist");
    let indexed = screen.cell(0, 1).expect("indexed cell should exist");
    let normal = screen.cell(0, 2).expect("normal cell should exist");

    assert_eq!(bright.ch, 'B');
    assert_eq!(bright.foreground, Some(TerminalColor::Ansi(11)));
    assert_eq!(bright.background, Some(TerminalColor::Ansi(12)));
    assert_eq!(indexed.ch, 'I');
    assert_eq!(indexed.foreground, Some(TerminalColor::Ansi(196)));
    assert_eq!(indexed.background, Some(TerminalColor::Ansi(236)));
    assert_eq!(normal.ch, 'N');
    assert_eq!(normal.foreground, None);
    assert_eq!(normal.background, None);
}

#[test]
fn screen_applies_truecolor_sgr_colors_to_cells() {
    let mut screen = TerminalScreen::new(4, 1);

    screen.feed(b"\x1b[38;2;10;20;30;48;2;200;210;220mT");

    let cell = screen.cell(0, 0).expect("truecolor cell should exist");
    assert_eq!(cell.ch, 'T');
    assert_eq!(cell.foreground, Some(TerminalColor::Rgb(10, 20, 30)));
    assert_eq!(cell.background, Some(TerminalColor::Rgb(200, 210, 220)));
}

#[test]
fn screen_retains_scrollback_when_lines_scroll_off_viewport() {
    let mut screen = TerminalScreen::new(6, 2);

    screen.feed(b"one\r\ntwo\r\nthree");

    assert_eq!(screen.visible_lines(), vec!["two   ", "three "]);
    assert_eq!(screen.scrollback_lines(), vec!["one   "]);
    assert_eq!(
        screen.all_lines(),
        vec![
            "one   ".to_string(),
            "two   ".to_string(),
            "three ".to_string()
        ]
    );
}

#[test]
fn screen_enforces_scrollback_limit() {
    let mut screen = TerminalScreen::with_scrollback_limit(4, 1, 2);

    screen.feed(b"aa\r\nbb\r\ncc\r\ndd");

    assert_eq!(screen.visible_lines(), vec!["dd  "]);
    assert_eq!(screen.scrollback_lines(), vec!["bb  ", "cc  "]);
}

#[test]
fn screen_searches_scrollback_and_visible_lines() {
    let mut screen = TerminalScreen::new(12, 2);

    screen.feed(b"alpha foo\r\nBeta FOO\r\nvisible foo");

    assert_eq!(
        screen.search(
            "foo",
            TerminalSearchOptions {
                case_sensitive: true
            }
        ),
        vec![
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
    assert_eq!(
        screen.search(
            "foo",
            TerminalSearchOptions {
                case_sensitive: false
            }
        ),
        vec![
            TerminalSearchMatch {
                line_index: 0,
                start_column: 6,
                end_column: 9,
            },
            TerminalSearchMatch {
                line_index: 1,
                start_column: 5,
                end_column: 8,
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
fn screen_plain_text_trims_terminal_padding_and_empty_tail() {
    let mut screen = TerminalScreen::new(8, 2);

    screen.feed(b"first\r\nsecond\r\n");

    assert_eq!(screen.plain_text(), "first\nsecond");
}

#[test]
fn screen_copies_text_range_across_history_and_visible_rows() {
    let mut screen = TerminalScreen::new(8, 2);

    screen.feed(b"first\r\nsecond\r\nthird");

    let copied = screen
        .text_in_range(TerminalTextRange {
            start: TerminalTextPoint {
                line_index: 2,
                column: 2,
            },
            end: TerminalTextPoint {
                line_index: 0,
                column: 1,
            },
        })
        .expect("range should be inside the terminal history");

    assert_eq!(copied, "irst\nsecond\nth");
}

#[test]
fn screen_tracks_bell_and_clears_on_take() {
    let mut screen = TerminalScreen::new(10, 3);
    assert!(!screen.take_bell());
    // BEL (0x07) sets the pending-bell flag.
    screen.feed(b"hi\x07");
    assert!(screen.take_bell());
    // take clears it.
    assert!(!screen.take_bell());
}

#[test]
fn screen_sets_title_from_osc() {
    let mut screen = TerminalScreen::new(10, 3);
    assert_eq!(screen.title(), None);
    // OSC 2 ; <title> BEL sets the window/icon title.
    screen.feed(b"\x1b]2;my-shell-title\x07");
    assert_eq!(screen.title(), Some("my-shell-title"));
}
