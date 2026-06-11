//! Pure cell↔pixel metric math for the terminal grid: deriving grid dimensions
//! from a client area + measured cell size, and locating a cell's pixel origin.
//!
//! These functions are the source of truth shared by the renderer (where to
//! draw each cell) and the PTY sizing path (how many cols/rows fit). Phases 3
//! (selection hit-testing) and 4 (pane rects) build on the same model.

#![cfg(windows)]

/// Number of grid columns and rows that fit in a client area, given the text
/// inset (both sides) and the measured cell size in pixels. Always ≥ 1×1.
pub fn grid_dimensions(
    client_width: i32,
    client_height: i32,
    inset_x: f32,
    inset_y: f32,
    cell_width: f32,
    cell_height: f32,
) -> (u16, u16) {
    if cell_width <= 0.0 || cell_height <= 0.0 {
        return (1, 1);
    }
    let usable_width = (client_width as f32 - inset_x * 2.0).max(0.0);
    let usable_height = (client_height as f32 - inset_y * 2.0).max(0.0);
    let cols = (usable_width / cell_width).floor().max(1.0) as u16;
    let rows = (usable_height / cell_height).floor().max(1.0) as u16;
    (cols, rows)
}

/// Inverse of [`cell_origin`]: the `(row, column)` whose cell contains the
/// client pixel `(x, y)`, or `None` if the point is left of / above the text
/// inset. The result is unbounded on the high side (callers clamp to the grid).
pub fn cell_at_pixel(
    x: i32,
    y: i32,
    inset_x: f32,
    inset_y: f32,
    cell_width: f32,
    cell_height: f32,
) -> Option<(usize, usize)> {
    if cell_width <= 0.0 || cell_height <= 0.0 {
        return None;
    }
    let local_x = x as f32 - inset_x;
    let local_y = y as f32 - inset_y;
    if local_x < 0.0 || local_y < 0.0 {
        return None;
    }
    let column = (local_x / cell_width).floor() as usize;
    let row = (local_y / cell_height).floor() as usize;
    Some((row, column))
}

/// Pixel origin (top-left) of the cell at `(row, column)`.
pub fn cell_origin(
    row: usize,
    column: usize,
    inset_x: f32,
    inset_y: f32,
    cell_width: f32,
    cell_height: f32,
) -> (f32, f32) {
    (
        inset_x + column as f32 * cell_width,
        inset_y + row as f32 * cell_height,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grid_dimensions_floor_divides_usable_area() {
        // (1024 - 16) / 8 = 126 cols; (720 - 16) / 18 = 39.1 → 39 rows.
        assert_eq!(grid_dimensions(1024, 720, 8.0, 8.0, 8.0, 18.0), (126, 39));
    }

    #[test]
    fn grid_dimensions_clamps_to_one() {
        assert_eq!(grid_dimensions(4, 4, 8.0, 8.0, 8.0, 18.0), (1, 1));
        assert_eq!(grid_dimensions(1024, 720, 8.0, 8.0, 0.0, 0.0), (1, 1));
    }

    #[test]
    fn grid_dimensions_fractional_cell_size() {
        // Measured Cascadia-ish metrics: 8.4 wide, 18.6 tall.
        // (1008 - 16)/8.4 = 118.09 → 118; (681 - 16)/18.6 = 35.7 → 35.
        assert_eq!(grid_dimensions(1008, 681, 8.0, 8.0, 8.4, 18.6), (118, 35));
    }

    #[test]
    fn cell_origin_offsets_by_inset_and_cell_size() {
        assert_eq!(cell_origin(0, 0, 8.0, 8.0, 8.0, 18.0), (8.0, 8.0));
        assert_eq!(cell_origin(2, 3, 8.0, 8.0, 8.0, 18.0), (32.0, 44.0));
    }

    #[test]
    fn cell_at_pixel_maps_client_point_to_grid_cell() {
        // Inset 8, cell 8x18 (matches the legacy hit-testing fixture).
        assert_eq!(cell_at_pixel(8, 8, 8.0, 8.0, 8.0, 18.0), Some((0, 0)));
        assert_eq!(cell_at_pixel(23, 25, 8.0, 8.0, 8.0, 18.0), Some((0, 1)));
        assert_eq!(cell_at_pixel(24, 26, 8.0, 8.0, 8.0, 18.0), Some((1, 2)));
        // Left of / above the inset → no cell.
        assert_eq!(cell_at_pixel(7, 8, 8.0, 8.0, 8.0, 18.0), None);
        assert_eq!(cell_at_pixel(8, 7, 8.0, 8.0, 8.0, 18.0), None);
    }

    #[test]
    fn cell_at_pixel_round_trips_with_cell_origin() {
        let (inset_x, inset_y, cw, ch) = (8.0_f32, 8.0_f32, 8.4_f32, 18.6_f32);
        for &(row, col) in &[(0usize, 0usize), (3, 7), (12, 40)] {
            let (ox, oy) = cell_origin(row, col, inset_x, inset_y, cw, ch);
            // The cell's own origin (+1px) must hit-test back to that cell.
            let hit = cell_at_pixel(ox as i32 + 1, oy as i32 + 1, inset_x, inset_y, cw, ch);
            assert_eq!(hit, Some((row, col)));
        }
    }
}
