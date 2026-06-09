//! Pure pane-rectangle layout: turn the worklane's column/pane structure into
//! pixel rects for the renderer. Columns lay out left-to-right (the worklane
//! strip); panes stack top-to-bottom within a column by height weight. When the
//! columns fit the viewport they stretch to fill it; when they overflow, they
//! keep their widths and the strip scrolls horizontally to keep the focused
//! column in view.

#![cfg(windows)]

/// One pane's position in the worklane layout (column-major).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PaneLayoutInput {
    pub column_index: usize,
    pub pane_index: usize,
    /// Relative/px width of this pane's column (shared by the column).
    pub column_width: f64,
    /// Height weight within the column (1.0 = equal share).
    pub pane_height: f64,
}

/// A pane's pixel rectangle in the window.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PaneRect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

/// Compute a pixel rect for each input pane (returned in input order). The
/// rects live inside the content box `(content_x, content_y, content_w,
/// content_h)`; `spacing` separates columns and stacked panes; the strip
/// scrolls so `focused_column_index` stays visible when columns overflow.
pub fn compute_pane_rects(
    panes: &[PaneLayoutInput],
    content_x: f32,
    content_y: f32,
    content_w: f32,
    content_h: f32,
    spacing: f32,
    focused_column_index: usize,
) -> Vec<PaneRect> {
    if panes.is_empty() || content_w <= 0.0 || content_h <= 0.0 {
        return vec![PaneRect { x: content_x, y: content_y, width: 0.0, height: 0.0 }; panes.len()];
    }

    // Distinct columns in left-to-right order, each with its width and panes.
    let mut column_order: Vec<usize> = Vec::new();
    for pane in panes {
        if !column_order.contains(&pane.column_index) {
            column_order.push(pane.column_index);
        }
    }
    column_order.sort_unstable();
    let n_cols = column_order.len();

    let column_width = |column_index: usize| -> f64 {
        panes
            .iter()
            .find(|p| p.column_index == column_index)
            .map(|p| p.column_width.max(1.0))
            .unwrap_or(1.0)
    };

    let total_spacing = spacing * (n_cols.saturating_sub(1)) as f32;
    let raw_total: f64 = column_order.iter().map(|&c| column_width(c)).sum();
    let usable_w = (content_w - total_spacing).max(1.0);

    // Columns scale to fill the viewport while each stays at least
    // MIN_COLUMN_WIDTH; once that floor can't be met they keep MIN_COLUMN_WIDTH
    // and the strip scrolls horizontally to the focused column.
    const MIN_COLUMN_WIDTH: f32 = 220.0;
    let would_fit = n_cols <= 1 || usable_w / n_cols as f32 >= MIN_COLUMN_WIDTH;
    let scale = if would_fit && raw_total > 0.0 {
        usable_w / raw_total as f32
    } else {
        1.0
    };

    // Column x positions and widths (content-local, before horizontal scroll).
    let mut col_x = Vec::with_capacity(n_cols);
    let mut col_w = Vec::with_capacity(n_cols);
    let mut cursor_x = 0.0_f32;
    for &c in &column_order {
        let w = (column_width(c) as f32 * scale).max(1.0);
        col_x.push(cursor_x);
        col_w.push(w);
        cursor_x += w + spacing;
    }
    let total_content_w = cursor_x - spacing;

    // Horizontal scroll to keep the focused column visible (overflow only).
    let h_scroll = if total_content_w <= content_w {
        0.0
    } else {
        let fc = column_order
            .iter()
            .position(|&c| c == focused_column_index)
            .unwrap_or(0);
        let (fx, fw) = (col_x[fc], col_w[fc]);
        let mut h = 0.0_f32;
        if fx + fw > content_w {
            h = fx + fw - content_w;
        }
        if fx < h {
            h = fx;
        }
        h.clamp(0.0, total_content_w - content_w)
    };

    // Build a rect per input pane.
    panes
        .iter()
        .map(|pane| {
            let ci = column_order
                .iter()
                .position(|&c| c == pane.column_index)
                .unwrap_or(0);
            let column = pane.column_index;

            // Panes of this column, ordered by pane_index, with their weights.
            let mut stack: Vec<(usize, f64)> = panes
                .iter()
                .filter(|p| p.column_index == column)
                .map(|p| (p.pane_index, p.pane_height.max(0.0)))
                .collect();
            stack.sort_by_key(|(idx, _)| *idx);
            let np = stack.len();
            let total_weight: f64 = stack.iter().map(|(_, w)| if *w <= 0.0 { 1.0 } else { *w }).sum();
            let total_weight = if total_weight <= 0.0 { np.max(1) as f64 } else { total_weight };
            let usable_h = (content_h - spacing * (np.saturating_sub(1)) as f32).max(1.0);

            let mut y = 0.0_f32;
            let mut height = usable_h;
            for (idx, weight) in &stack {
                let weight = if *weight <= 0.0 { 1.0 } else { *weight };
                let h = (usable_h as f64 * weight / total_weight) as f32;
                if *idx == pane.pane_index {
                    height = h;
                    break;
                }
                y += h + spacing;
            }

            PaneRect {
                x: content_x + col_x[ci] - h_scroll,
                y: content_y + y,
                width: col_w[ci],
                height,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(column_index: usize, pane_index: usize, column_width: f64, pane_height: f64) -> PaneLayoutInput {
        PaneLayoutInput { column_index, pane_index, column_width, pane_height }
    }

    #[test]
    fn single_pane_fills_content_box() {
        let rects = compute_pane_rects(&[input(0, 0, 100.0, 1.0)], 8.0, 8.0, 1000.0, 700.0, 6.0, 0);
        assert_eq!(rects.len(), 1);
        assert_eq!(rects[0], PaneRect { x: 8.0, y: 8.0, width: 1000.0, height: 700.0 });
    }

    #[test]
    fn two_equal_columns_split_width_side_by_side() {
        // content_w = raw(1024) + spacing(6) so columns keep their 512px width.
        let panes = [input(0, 0, 512.0, 1.0), input(1, 0, 512.0, 1.0)];
        let rects = compute_pane_rects(&panes, 8.0, 8.0, 1030.0, 720.0, 6.0, 0);
        assert_eq!(rects[0], PaneRect { x: 8.0, y: 8.0, width: 512.0, height: 720.0 });
        assert_eq!(rects[1], PaneRect { x: 8.0 + 512.0 + 6.0, y: 8.0, width: 512.0, height: 720.0 });
    }

    #[test]
    fn two_stacked_panes_split_height() {
        let panes = [input(0, 0, 100.0, 1.0), input(0, 1, 100.0, 1.0)];
        let rects = compute_pane_rects(&panes, 0.0, 0.0, 800.0, 720.0, 6.0, 0);
        // usable height = 720 - 6 = 714; each pane = 357.
        assert_eq!(rects[0], PaneRect { x: 0.0, y: 0.0, width: 800.0, height: 357.0 });
        assert_eq!(rects[1], PaneRect { x: 0.0, y: 363.0, width: 800.0, height: 357.0 });
    }

    #[test]
    fn weighted_stack_respects_height_weights() {
        // Top pane weight 2, bottom weight 1 → 2:1 split of 720 (no spacing).
        let panes = [input(0, 0, 100.0, 2.0), input(0, 1, 100.0, 1.0)];
        let rects = compute_pane_rects(&panes, 0.0, 0.0, 800.0, 720.0, 0.0, 0);
        assert_eq!(rects[0].height, 480.0);
        assert_eq!(rects[1].height, 240.0);
        assert_eq!(rects[1].y, 480.0);
    }

    #[test]
    fn overflowing_columns_scroll_to_focused() {
        // Four 400px columns in an 800px content box → overflow; focus col 3.
        let panes: Vec<_> = (0..4).map(|c| input(c, 0, 400.0, 1.0)).collect();
        let rects = compute_pane_rects(&panes, 0.0, 0.0, 800.0, 600.0, 0.0, 3);
        // Columns at content-x 0,400,800,1200 (width 400). Focused col 3 right
        // edge = 1600; scroll = 1600 - 800 = 800 → its on-screen x = 1200 - 800 = 400.
        assert_eq!(rects[3].x, 400.0);
        assert_eq!(rects[3].width, 400.0);
    }
}
