/**
 * Monospace cell metrics for the terminal view and takeover grid measurement.
 *
 * The terminal renders at a fixed font; takeover (§2.6) converts the terminal
 * view's pixel box into a cols×rows grid at this cell size and sends it in
 * `lease.request`. The advance-width ratio (~0.6em) is the standard monospace
 * figure for Menlo / the platform monospace face.
 */

export const TERMINAL_FONT_SIZE = 12;
export const TERMINAL_LINE_HEIGHT = 16;
/** Advance width of one monospace glyph at {@link TERMINAL_FONT_SIZE}. */
export const TERMINAL_CELL_WIDTH = TERMINAL_FONT_SIZE * 0.6;

/**
 * Convert a pixel box into a terminal grid. Floors each axis (a partial cell is
 * not usable) and guarantees at least 1×1 so a zero-size layout never yields an
 * empty grid the Mac would clamp oddly.
 */
export function measureGrid(
  widthPx: number,
  heightPx: number,
  cellWidth: number = TERMINAL_CELL_WIDTH,
  cellHeight: number = TERMINAL_LINE_HEIGHT,
): { cols: number; rows: number } {
  return {
    cols: Math.max(1, Math.floor(widthPx / cellWidth)),
    rows: Math.max(1, Math.floor(heightPx / cellHeight)),
  };
}
