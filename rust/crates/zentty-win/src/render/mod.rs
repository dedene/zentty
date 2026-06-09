//! Direct2D + DirectWrite render surface for the Zentty desktop window.
//!
//! Phase 1 scope: clear the window to a dark background and draw the live
//! shell's text lines in crisp monospace DirectWrite glyphs, replacing the old
//! GDI `TextOutW` path.
//!
//! Architecture: a DXGI flip-model swapchain (`CreateSwapChainForHwnd`) bound
//! to an `ID2D1DeviceContext` via a D2D bitmap over the swapchain back buffer.
//! This is the path DWM composites correctly for a Win32 hwnd (a plain
//! `ID2D1HwndRenderTarget` did not present under DWM in testing). All COM
//! objects use the `windows` crate's ref-counted handles (RAII — no manual
//! `Release`).
//!
//! Device loss: `Present`/`ResizeBuffers` return `DXGI_ERROR_DEVICE_REMOVED`
//! or `DXGI_ERROR_DEVICE_RESET`, and D2D `EndDraw` returns
//! `D2DERR_RECREATE_TARGET` (HRESULT `0x8899_000C`). Any of these drops the
//! device-dependent objects; the next `render` rebuilds the whole pipeline.

#![cfg(windows)]

pub mod layout;
pub mod metrics;

use windows::Win32::Foundation::{E_FAIL, HMODULE, HWND, RECT};
use windows::Win32::Graphics::Direct2D::Common::{
    D2D1_ALPHA_MODE_IGNORE, D2D1_COLOR_F, D2D1_PIXEL_FORMAT, D2D_RECT_F,
};
use windows::Win32::Graphics::Direct2D::D2D1_ROUNDED_RECT;
use windows::Win32::Graphics::Direct2D::{
    D2D1CreateFactory, D2D1_ANTIALIAS_MODE_ALIASED, D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
    D2D1_BITMAP_OPTIONS_TARGET, D2D1_BITMAP_PROPERTIES1, D2D1_DEVICE_CONTEXT_OPTIONS_NONE,
    D2D1_DRAW_TEXT_OPTIONS_CLIP, D2D1_DRAW_TEXT_OPTIONS_NONE, D2D1_FACTORY_TYPE_SINGLE_THREADED,
    D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE,
    ID2D1Bitmap1, ID2D1DeviceContext, ID2D1Factory1, ID2D1SolidColorBrush, ID2D1StrokeStyle,
};
use windows::Win32::Graphics::Direct3D::{D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_WARP};
use windows::Win32::Graphics::Direct3D11::{
    D3D11CreateDevice, D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_SDK_VERSION, ID3D11Device,
};
use windows::Win32::Graphics::DirectWrite::{
    DWRITE_FACTORY_TYPE_SHARED, DWRITE_FONT_STRETCH_NORMAL, DWRITE_FONT_STYLE_NORMAL,
    DWRITE_FONT_WEIGHT_BOLD, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_MEASURING_MODE_NATURAL,
    DWRITE_PARAGRAPH_ALIGNMENT_CENTER, DWRITE_TEXT_METRICS, DWRITE_TRIMMING,
    DWRITE_TRIMMING_GRANULARITY_CHARACTER, DWRITE_WORD_WRAPPING_NO_WRAP, DWriteCreateFactory,
    IDWriteFactory, IDWriteFontCollection, IDWriteTextFormat, IDWriteTextLayout,
};
use windows::Win32::Graphics::Dxgi::Common::{
    DXGI_ALPHA_MODE_IGNORE, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC,
};
use windows::Win32::Graphics::Dxgi::{
    CreateDXGIFactory2, DXGI_CREATE_FACTORY_FLAGS, DXGI_PRESENT, DXGI_SCALING_NONE,
    DXGI_SWAP_CHAIN_DESC1, DXGI_SWAP_CHAIN_FLAG, DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL,
    DXGI_USAGE_RENDER_TARGET_OUTPUT, IDXGIDevice, IDXGIFactory2, IDXGISurface, IDXGISwapChain1,
};
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::WindowsAndMessaging::GetClientRect;
use windows::core::{Interface, PCWSTR, Result};
use zentty_core::theme::{Rgb, Theme, default_dark};
use zentty_terminal::screen::{TerminalColor, TerminalScreen, TerminalTextRange};

/// Monospace font fallback chain, most-preferred first.
const FONT_FALLBACK_CHAIN: [&str; 4] =
    ["Cascadia Mono", "Cascadia Code", "Consolas", "Courier New"];

/// Em size (DIP) of the terminal font. Pixel cell metrics are derived in a
/// later phase; Phase 1 only needs legible monospace text.
const FONT_SIZE_DIP: f32 = 14.0;

/// Left/top text inset in DIPs, mirroring the legacy GDI layout constants so
/// mouse hit-testing geometry stays aligned for now.
const TEXT_INSET_LEFT: f32 = 8.0;
const TEXT_INSET_TOP: f32 = 8.0;
/// Per-line advance in DIPs, matching the legacy `DESKTOP_LINE_HEIGHT`.
const LINE_HEIGHT_DIP: f32 = 18.0;

/// `D2DERR_RECREATE_TARGET` (0x8899_000C): the render target's device is lost
/// and must be recreated. Defined locally because the `windows` crate does not
/// export the D2D error HRESULT constants.
const D2DERR_RECREATE_TARGET: windows::core::HRESULT =
    windows::core::HRESULT(0x8899_000C_u32 as i32);

/// A null-terminated UTF-16 buffer for a `PCWSTR` argument.
fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

/// Build a Direct2D color from 8-bit sRGB components (alpha = 1.0).
const fn rgb(r: u8, g: u8, b: u8) -> D2D1_COLOR_F {
    rgba(r, g, b, 1.0)
}

/// Build a Direct2D color from 8-bit sRGB components with explicit alpha.
const fn rgba(r: u8, g: u8, b: u8, a: f32) -> D2D1_COLOR_F {
    D2D1_COLOR_F {
        r: r as f32 / 255.0,
        g: g as f32 / 255.0,
        b: b as f32 / 255.0,
        a,
    }
}

/// Default dark chrome background/foreground (used by sidebar/overlay/pane
/// chrome; the terminal grid colors come from the active [`Theme`]).
pub const DARK_BG: D2D1_COLOR_F = rgb(0x1e, 0x1e, 0x2e);
pub const DARK_FG: D2D1_COLOR_F = rgb(0xcd, 0xd6, 0xf4);

/// Build a Direct2D color from a theme RGB tuple.
fn rgb_tuple(c: Rgb) -> D2D1_COLOR_F {
    rgb(c.0, c.1, c.2)
}

/// Resolve a terminal cell color through the active theme.
fn theme_cell_color(theme: &Theme, color: TerminalColor) -> D2D1_COLOR_F {
    rgb_tuple(match color {
        TerminalColor::Ansi(index) => theme.ansi_color(index),
        TerminalColor::Rgb(r, g, b) => (r, g, b),
    })
}
/// Selection highlight background (Phase 7 will theme it).
pub const SELECTION_BG: D2D1_COLOR_F = rgb(0x45, 0x47, 0x5a);
/// Teal accent for the focused pane (icon-derived; Phase 7 will theme it).
pub const ACCENT: D2D1_COLOR_F = rgb(0x94, 0xe2, 0xd5);
/// Pane title-bar background (unfocused / focused).
const PANE_TITLE_BG: D2D1_COLOR_F = rgb(0x31, 0x32, 0x44);
const PANE_TITLE_BG_FOCUSED: D2D1_COLOR_F = rgb(0x3b, 0x42, 0x52);
const PANE_BORDER: D2D1_COLOR_F = rgb(0x45, 0x47, 0x5a);

/// Pane title-bar height and inner padding (px).
pub const PANE_TITLE_H: f32 = 22.0;
pub const PANE_PAD: f32 = 4.0;
/// Gap between columns / stacked panes (px).
pub const COLUMN_SPACING: f32 = 6.0;

/// The inner grid rect of a pane (below the title bar, inset by padding).
pub fn pane_content_rect(rect: layout::PaneRect) -> layout::PaneRect {
    layout::PaneRect {
        x: rect.x + PANE_PAD,
        y: rect.y + PANE_TITLE_H,
        width: (rect.width - PANE_PAD * 2.0).max(0.0),
        height: (rect.height - PANE_TITLE_H - PANE_PAD).max(0.0),
    }
}

/// One pane's render inputs: its layout slot, title, focus, terminal screen,
/// and active selection.
pub struct PaneFrame<'a> {
    pub layout: layout::PaneLayoutInput,
    pub title: &'a str,
    pub focused: bool,
    pub screen: &'a TerminalScreen,
    pub selection: Option<TerminalTextRange>,
}

/// Sidebar panel + body colors (Phase 7 will theme).
const SIDEBAR_BG: D2D1_COLOR_F = rgb(0x18, 0x18, 0x25);
const SIDEBAR_ACTIVE_BG: D2D1_COLOR_F = rgb(0x2a, 0x2b, 0x3c);
const SIDEBAR_ROW_FOCUSED_BG: D2D1_COLOR_F = rgb(0x31, 0x32, 0x44);
const SIDEBAR_BORDER: D2D1_COLOR_F = rgb(0x11, 0x11, 0x1b);
const SIDEBAR_DIM_FG: D2D1_COLOR_F = rgb(0x9a, 0xa0, 0xb5);

/// Agent/shell status for a pane's sidebar pill.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PaneStatusKind {
    Ready,
    Working,
    Idle,
}

/// Pill label + color for a status (state-appropriate styling).
pub fn status_pill_style(kind: PaneStatusKind) -> (&'static str, D2D1_COLOR_F) {
    match kind {
        PaneStatusKind::Ready => ("Ready", rgb(0xa6, 0xe3, 0xa1)),
        PaneStatusKind::Working => ("Working", rgb(0xf9, 0xe2, 0xaf)),
        PaneStatusKind::Idle => ("Idle", rgb(0x93, 0x99, 0xb2)),
    }
}

/// One pane row in the sidebar (owned so the model outlives session borrows).
pub struct SidebarPaneRow {
    pub title: String,
    pub focused: bool,
    pub status: PaneStatusKind,
}

/// One worklane group in the sidebar: a header plus its pane rows.
pub struct SidebarWorklane {
    pub title: String,
    pub is_active: bool,
    pub color: Option<(u8, u8, u8)>,
    pub panes: Vec<SidebarPaneRow>,
}

/// The rendered sidebar: a fixed-width left panel of worklane groups.
pub struct SidebarModel {
    pub width: f32,
    pub worklanes: Vec<SidebarWorklane>,
}

/// Sidebar row height and indents (px).
const SIDEBAR_ROW_H: f32 = 26.0;
const SIDEBAR_PAD: f32 = 10.0;
const SIDEBAR_PANE_INDENT: f32 = 22.0;

/// Overlay colors (scrim + floating panel).
const OVERLAY_SCRIM: D2D1_COLOR_F = rgba(0x0d, 0x0d, 0x14, 0.55);
const OVERLAY_PANEL_BG: D2D1_COLOR_F = rgb(0x24, 0x25, 0x36);
const OVERLAY_PANEL_BORDER: D2D1_COLOR_F = rgb(0x45, 0x47, 0x5a);
const OVERLAY_SELECTED_BG: D2D1_COLOR_F = rgb(0x39, 0x3b, 0x54);
const OVERLAY_SUBTLE_FG: D2D1_COLOR_F = rgb(0x9a, 0xa0, 0xb5);

/// One command-palette row.
pub struct PaletteItem {
    pub title: String,
    pub subtitle: String,
    pub category: String,
    pub selected: bool,
}

/// Command-palette overlay model: query field + filtered item list.
pub struct PaletteModel {
    pub query: String,
    pub items: Vec<PaletteItem>,
}

/// Global-search overlay model: query + match position/count.
pub struct SearchModel {
    pub query: String,
    pub selected: Option<usize>,
    pub total: usize,
}

/// A floating overlay drawn over a dimmed window (only one at a time).
pub enum Overlay {
    Palette(PaletteModel),
    GlobalSearch(SearchModel),
}

/// Whether the combined-buffer cell `(line, column)` falls inside a normalized
/// (start ≤ end) selection range.
fn range_contains(range: &TerminalTextRange, line: usize, column: usize) -> bool {
    let (start, end) = (range.start, range.end);
    if line < start.line_index || line > end.line_index {
        false
    } else if start.line_index == end.line_index {
        column >= start.column && column < end.column
    } else if line == start.line_index {
        column >= start.column
    } else if line == end.line_index {
        column < end.column
    } else {
        true
    }
}

/// Device-dependent pipeline: D3D11 device, DXGI swapchain, D2D device context,
/// and the bitmap bound to the current back buffer. Rebuilt on device loss.
struct DeviceResources {
    swapchain: IDXGISwapChain1,
    context: ID2D1DeviceContext,
    _target_bitmap: ID2D1Bitmap1,
}

/// Safe Direct2D/DirectWrite renderer for one window.
pub struct Renderer {
    hwnd: HWND,
    d2d_factory: ID2D1Factory1,
    text_format: IDWriteTextFormat,
    text_format_bold: IDWriteTextFormat,
    /// UI text formats (sidebar rows / pane titles) with ellipsis trimming, so
    /// chrome text degrades to '…' instead of hard-chopping mid-glyph. Kept
    /// separate from the grid formats (a 1-char cell would render '…').
    text_format_ui: IDWriteTextFormat,
    text_format_ui_bold: IDWriteTextFormat,
    /// Measured monospace cell size (px): glyph advance width × line height.
    cell_width: f32,
    cell_height: f32,
    /// Active terminal color theme.
    theme: Theme,
    /// DirectWrite factory, kept so text formats can be rebuilt on DPI change.
    dwrite: IDWriteFactory,
    /// Effective DPI driving the font size (per-monitor; 96 = 100%).
    dpi: f32,
    /// Top-left pixel of the focused pane's grid from the last
    /// `render_window`, so mouse hit-testing maps to the cells actually drawn
    /// (the grid is offset by the sidebar and the pane title bar).
    focused_grid_origin: Option<(f32, f32)>,
    /// `None` until first paint or after a device-loss drop; rebuilt lazily.
    device: Option<DeviceResources>,
}

impl Renderer {
    /// Create the device-independent resources (D2D factory, DWrite factory,
    /// normal + bold monospace text formats) and measure the cell size. The GPU
    /// device + swapchain are created lazily on the first paint. The font is
    /// scaled by the window DPI so text is correctly sized on hi-DPI monitors.
    pub fn new(hwnd: HWND) -> Result<Self> {
        let d2d_factory: ID2D1Factory1 =
            unsafe { D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, None)? };
        let dwrite: IDWriteFactory = unsafe { DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED)? };
        let dpi = effective_dpi(hwnd);
        let (text_format, text_format_bold, text_format_ui, text_format_ui_bold, cell_width, cell_height) =
            unsafe { build_formats(&dwrite, dpi)? };
        Ok(Self {
            hwnd,
            d2d_factory,
            text_format,
            text_format_bold,
            text_format_ui,
            text_format_ui_bold,
            cell_width,
            cell_height,
            theme: default_dark(),
            dwrite,
            dpi,
            focused_grid_origin: None,
            device: None,
        })
    }

    /// Measured monospace cell size in pixels (advance width, line height).
    pub fn cell_size(&self) -> (f32, f32) {
        (self.cell_width, self.cell_height)
    }

    /// Top-left pixel of the focused pane's grid as last drawn, for mouse
    /// hit-testing. `None` before the first `render_window` (or after an
    /// error/empty-state paint).
    pub fn focused_grid_origin(&self) -> Option<(f32, f32)> {
        self.focused_grid_origin
    }

    /// Rebuild the text formats for a new DPI (from `WM_DPICHANGED`).
    pub fn update_dpi(&mut self, dpi: u32) {
        let dpi = dpi as f32;
        if (dpi - self.dpi).abs() < 0.5 {
            return;
        }
        if let Ok((normal, bold, ui, ui_bold, cell_w, cell_h)) =
            unsafe { build_formats(&self.dwrite, dpi) }
        {
            self.text_format = normal;
            self.text_format_bold = bold;
            self.text_format_ui = ui;
            self.text_format_ui_bold = ui_bold;
            self.cell_width = cell_w;
            self.cell_height = cell_h;
            self.dpi = dpi;
        }
    }

    /// Switch the active terminal color theme at runtime.
    pub fn set_theme(&mut self, theme: Theme) {
        self.theme = theme;
    }

    /// The active theme's name.
    pub fn theme_name(&self) -> &str {
        self.theme.name
    }

    /// Build (or rebuild) the D3D device, swapchain, and D2D device context
    /// bound to the back buffer, sized to the current client area.
    fn create_device_resources(&self) -> Result<DeviceResources> {
        let (width, height) = client_pixel_size(self.hwnd);
        let (width, height) = (width.max(1), height.max(1));

        // D3D11 device with BGRA support (required for D2D interop). Fall back
        // to the WARP software rasterizer if no hardware device is available.
        let d3d_device = unsafe { create_d3d_device() }?;
        let dxgi_device: IDXGIDevice = d3d_device.cast()?;
        let dxgi_factory: IDXGIFactory2 =
            unsafe { CreateDXGIFactory2(DXGI_CREATE_FACTORY_FLAGS(0))? };

        let swap_desc = DXGI_SWAP_CHAIN_DESC1 {
            Width: width,
            Height: height,
            Format: DXGI_FORMAT_B8G8R8A8_UNORM,
            Stereo: false.into(),
            SampleDesc: DXGI_SAMPLE_DESC {
                Count: 1,
                Quality: 0,
            },
            BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
            BufferCount: 2,
            Scaling: DXGI_SCALING_NONE,
            SwapEffect: DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL,
            AlphaMode: DXGI_ALPHA_MODE_IGNORE,
            Flags: 0,
        };
        let swapchain = unsafe {
            dxgi_factory.CreateSwapChainForHwnd(
                &d3d_device,
                self.hwnd,
                &swap_desc,
                None,
                None,
            )?
        };

        let d2d_device = unsafe { self.d2d_factory.CreateDevice(&dxgi_device)? };
        let context =
            unsafe { d2d_device.CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE)? };
        let target_bitmap = unsafe { create_target_bitmap(&context, &swapchain)? };
        unsafe { context.SetTarget(&target_bitmap) };
        // Grayscale AA reads cleaner than ClearType for monospace on a dark
        // background (no color fringing).
        unsafe { context.SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE) };

        Ok(DeviceResources {
            swapchain,
            context,
            _target_bitmap: target_bitmap,
        })
    }

    /// Resize the swapchain back buffer to the new client pixel size (from
    /// `WM_SIZE`). A missing device is fine: it is recreated at the new size on
    /// next paint.
    pub fn resize(&mut self, width: u32, height: u32) {
        let Some(device) = self.device.as_ref() else {
            return;
        };
        let (width, height) = (width.max(1), height.max(1));
        unsafe {
            // Release the old back-buffer bitmap before resizing the swapchain.
            device.context.SetTarget(None);
        }
        // Drop and rebuild bitmap binding around ResizeBuffers. Because the
        // bitmap is owned by DeviceResources, take ownership to drop it first.
        let device = self.device.take().expect("checked above");
        let DeviceResources {
            swapchain,
            context,
            _target_bitmap,
        } = device;
        drop(_target_bitmap);
        let resized = unsafe {
            swapchain.ResizeBuffers(
                0,
                width,
                height,
                DXGI_FORMAT_B8G8R8A8_UNORM,
                DXGI_SWAP_CHAIN_FLAG(0),
            )
        };
        if resized.is_err() {
            // Device lost during resize: leave device None to fully rebuild.
            return;
        }
        match unsafe { create_target_bitmap(&context, &swapchain) } {
            Ok(target_bitmap) => {
                unsafe { context.SetTarget(&target_bitmap) };
                self.device = Some(DeviceResources {
                    swapchain,
                    context,
                    _target_bitmap: target_bitmap,
                });
            }
            Err(_) => {
                // Rebuild from scratch on next paint.
            }
        }
    }

    /// Run one frame: ensure the device, `BeginDraw`, invoke `draw`, then
    /// `EndDraw` + `Present`. Device loss (`D2DERR_RECREATE_TARGET` on EndDraw,
    /// `DXGI_ERROR_DEVICE_REMOVED`/`_RESET` on Present) drops the pipeline so
    /// the next frame rebuilds it. `draw` errors are surfaced after a clean
    /// `EndDraw` so the begin/end pair stays balanced.
    fn with_frame<F>(&mut self, draw: F) -> Result<()>
    where
        F: FnOnce(&ID2D1DeviceContext, &ID2D1SolidColorBrush) -> Result<()>,
    {
        if self.device.is_none() {
            self.device = Some(self.create_device_resources()?);
        }
        let device = self.device.as_ref().expect("device just set");
        let ctx = device.context.clone();
        let swapchain = device.swapchain.clone();

        let draw_result = unsafe {
            ctx.BeginDraw();
            ctx.CreateSolidColorBrush(&DARK_FG, None)
                .and_then(|brush| draw(&ctx, &brush))
        };
        match unsafe { ctx.EndDraw(None, None) } {
            Ok(()) => {}
            Err(err) if err.code() == D2DERR_RECREATE_TARGET => {
                self.drop_device();
                return Ok(());
            }
            Err(err) => return Err(err),
        }
        draw_result?;
        // Present with vsync.
        if unsafe { swapchain.Present(1, DXGI_PRESENT(0)) }.is_err() {
            self.drop_device();
        }
        Ok(())
    }

    /// Draw a centered empty state: a primary line plus dimmed hint lines.
    pub fn render_empty_state(&mut self, lines: &[&str]) -> Result<()> {
        self.focused_grid_origin = None;
        let (client_w, client_h) = client_pixel_size(self.hwnd);
        let bg = rgb_tuple(self.theme.background);
        let primary = rgb_tuple(self.theme.foreground);
        let (cell_w, cell_h) = (self.cell_width.max(7.0), self.cell_height.max(16.0));
        let row_h = cell_h + 8.0;
        let total_h = lines.len() as f32 * row_h;
        let start_y = (client_h as f32 - total_h) * 0.5;
        let text_format = self.text_format.clone();
        self.with_frame(|ctx, brush| unsafe {
            ctx.Clear(Some(&bg));
            for (index, line) in lines.iter().enumerate() {
                let est_width = line.chars().count() as f32 * cell_w;
                let left = ((client_w as f32 - est_width) * 0.5).max(0.0);
                let top = start_y + index as f32 * row_h;
                brush.SetColor(if index == 0 { &primary } else { &OVERLAY_SUBTLE_FG });
                let utf16: Vec<u16> = line.encode_utf16().collect();
                let rect = D2D_RECT_F {
                    left,
                    top,
                    right: client_w as f32,
                    bottom: top + row_h,
                };
                ctx.DrawText(
                    &utf16,
                    &text_format,
                    &rect,
                    brush,
                    D2D1_DRAW_TEXT_OPTIONS_NONE,
                    DWRITE_MEASURING_MODE_NATURAL,
                );
            }
            Ok(())
        })
    }

    /// Clear to the theme background and draw each line in the theme foreground.
    /// Used for the runtime-error fallback; the live terminal uses
    /// [`render_window`](Self::render_window).
    pub fn render(&mut self, lines: &[String]) -> Result<()> {
        self.focused_grid_origin = None;
        let right = client_pixel_size(self.hwnd).0 as f32;
        let bg = rgb_tuple(self.theme.background);
        let fg = rgb_tuple(self.theme.foreground);
        let text_format = self.text_format.clone();
        self.with_frame(|ctx, brush| unsafe {
            ctx.Clear(Some(&bg));
            brush.SetColor(&fg);
            for (index, line) in lines.iter().enumerate() {
                let text = line.trim_end();
                if text.is_empty() {
                    continue;
                }
                let top = TEXT_INSET_TOP + index as f32 * LINE_HEIGHT_DIP;
                let rect = D2D_RECT_F {
                    left: TEXT_INSET_LEFT,
                    top,
                    right,
                    bottom: top + LINE_HEIGHT_DIP,
                };
                let utf16: Vec<u16> = text.encode_utf16().collect();
                ctx.DrawText(
                    &utf16,
                    &text_format,
                    &rect,
                    brush,
                    D2D1_DRAW_TEXT_OPTIONS_NONE,
                    DWRITE_MEASURING_MODE_NATURAL,
                );
            }
            Ok(())
        })
    }

    /// Draw the whole window: the optional left sidebar panel, then the
    /// worklane's panes (columns left-to-right, each with a title bar,
    /// focus-accented border, and its terminal grid clipped to its rect) in the
    /// area to the right of the sidebar.
    pub fn render_window(
        &mut self,
        sidebar: Option<SidebarModel>,
        frames: &[PaneFrame],
        overlay: Option<Overlay>,
        cursor_on: bool,
    ) -> Result<()> {
        let theme = self.theme.clone();
        let default_bg = rgb_tuple(theme.background);
        let (cell_w, cell_h) = (self.cell_width, self.cell_height);
        let (client_w, client_h) = client_pixel_size(self.hwnd);
        // Sidebar chrome scales with the monitor DPI (the fonts already do).
        let scale = self.dpi / 96.0;
        let sidebar_width = sidebar.as_ref().map(|s| s.width * scale).unwrap_or(0.0);
        // Pane content box, offset to the right of the sidebar.
        let content_x = sidebar_width + TEXT_INSET_LEFT;
        let content_w = (client_w as f32 - content_x - TEXT_INSET_LEFT).max(0.0);
        let content_h = (client_h as f32 - TEXT_INSET_TOP * 2.0).max(0.0);
        let inputs: Vec<layout::PaneLayoutInput> = frames.iter().map(|f| f.layout).collect();
        let focused_col = frames
            .iter()
            .find(|f| f.focused)
            .map(|f| f.layout.column_index)
            .unwrap_or(0);
        let rects = layout::compute_pane_rects(
            &inputs,
            content_x,
            TEXT_INSET_TOP,
            content_w,
            content_h,
            COLUMN_SPACING,
            focused_col,
        );
        self.focused_grid_origin = frames
            .iter()
            .zip(rects.iter())
            .find(|(frame, _)| frame.focused)
            .or_else(|| frames.iter().zip(rects.iter()).next())
            .map(|(_, rect)| {
                let content = pane_content_rect(*rect);
                (content.x, content.y)
            });
        let text_format = self.text_format.clone();
        let text_format_bold = self.text_format_bold.clone();
        let text_format_ui = self.text_format_ui.clone();
        let text_format_ui_bold = self.text_format_ui_bold.clone();
        // The focus ring only disambiguates when more than one pane is shown;
        // with a single pane it is pure decoration (matches Windows Terminal).
        let show_focus_ring = frames.len() > 1;

        self.with_frame(|ctx, brush| unsafe {
            ctx.Clear(Some(&default_bg));
            for (frame, rect) in frames.iter().zip(rects.iter()) {
                draw_pane_chrome(
                    ctx,
                    brush,
                    *rect,
                    frame.title,
                    frame.focused,
                    show_focus_ring,
                    &text_format_ui,
                );
                draw_grid_in_rect(
                    ctx,
                    brush,
                    frame.screen,
                    pane_content_rect(*rect),
                    frame.selection,
                    &text_format,
                    &text_format_bold,
                    cell_w,
                    cell_h,
                    &theme,
                    cursor_on,
                );
            }
            if let Some(model) = sidebar.as_ref() {
                draw_sidebar(
                    ctx,
                    brush,
                    model,
                    client_h as f32,
                    &text_format_ui,
                    &text_format_ui_bold,
                    cell_w,
                    scale,
                );
            }
            if let Some(overlay) = overlay.as_ref() {
                draw_overlay(
                    ctx,
                    brush,
                    overlay,
                    client_w as f32,
                    client_h as f32,
                    &text_format,
                    &text_format_bold,
                );
            }
            Ok(())
        })
    }

    /// Drop the device-dependent pipeline so the next paint rebuilds it.
    fn drop_device(&mut self) {
        self.device = None;
    }
}

/// Draw a pane's title bar and focus-accented border.
unsafe fn draw_pane_chrome(
    ctx: &ID2D1DeviceContext,
    brush: &ID2D1SolidColorBrush,
    rect: layout::PaneRect,
    title: &str,
    focused: bool,
    show_focus_ring: bool,
    text_format: &IDWriteTextFormat,
) {
    unsafe {
        // Title bar.
        let title_rect = D2D_RECT_F {
            left: rect.x,
            top: rect.y,
            right: rect.x + rect.width,
            bottom: rect.y + PANE_TITLE_H,
        };
        brush.SetColor(if focused {
            &PANE_TITLE_BG_FOCUSED
        } else {
            &PANE_TITLE_BG
        });
        ctx.FillRectangle(&title_rect, brush);

        // Title text (paragraph-centered by the format; the rect spans the full
        // title-bar height so the baseline is not double-shifted).
        brush.SetColor(if focused { &ACCENT } else { &DARK_FG });
        let text_rect = D2D_RECT_F {
            left: rect.x + PANE_PAD * 2.0,
            top: rect.y,
            right: rect.x + rect.width - PANE_PAD,
            bottom: rect.y + PANE_TITLE_H,
        };
        let utf16: Vec<u16> = title.encode_utf16().collect();
        if !utf16.is_empty() {
            ctx.DrawText(
                &utf16,
                text_format,
                &text_rect,
                brush,
                D2D1_DRAW_TEXT_OPTIONS_CLIP,
                DWRITE_MEASURING_MODE_NATURAL,
            );
        }

        // Border. The bright teal focus ring only disambiguates when more than
        // one pane is shown; with a lone pane draw the normal border instead.
        let ring = focused && show_focus_ring;
        let border_rect = D2D_RECT_F {
            left: rect.x + 0.5,
            top: rect.y + 0.5,
            right: rect.x + rect.width - 0.5,
            bottom: rect.y + rect.height - 0.5,
        };
        brush.SetColor(if ring { &ACCENT } else { &PANE_BORDER });
        ctx.DrawRectangle(
            &border_rect,
            brush,
            if ring { 1.5 } else { 1.0 },
            None::<&ID2D1StrokeStyle>,
        );
    }
}

/// Draw a terminal `screen` as a styled cell grid inside `content` (pixel rect),
/// clipped to it. Cells are offset to the content origin; the viewport honors
/// the screen's scroll-back offset and the cursor only shows at the live bottom.
#[allow(clippy::too_many_arguments)]
unsafe fn draw_grid_in_rect(
    ctx: &ID2D1DeviceContext,
    brush: &ID2D1SolidColorBrush,
    screen: &TerminalScreen,
    content: layout::PaneRect,
    selection: Option<TerminalTextRange>,
    text_format: &IDWriteTextFormat,
    text_format_bold: &IDWriteTextFormat,
    cell_w: f32,
    cell_h: f32,
    theme: &Theme,
    cursor_on: bool,
) {
    if content.width <= 0.0 || content.height <= 0.0 {
        return;
    }
    let default_bg = rgb_tuple(theme.background);
    let default_fg = rgb_tuple(theme.foreground);
    let cursor_color = rgb_tuple(theme.cursor);
    let selection_color = rgb_tuple(theme.selection);
    let clip = D2D_RECT_F {
        left: content.x,
        top: content.y,
        right: content.x + content.width,
        bottom: content.y + content.height,
    };
    let (cursor_row, cursor_col) = screen.cursor_position();
    // Cursor shows only in the live view, and blinks via `cursor_on`.
    let cursor_visible = cursor_on && screen.cursor_visible() && screen.view_scroll() == 0;
    let scrollback_len = screen.scrollback_len();
    let top_line = scrollback_len - screen.view_scroll().min(scrollback_len);

    // Only draw cells that can fall inside the content rect.
    let fit_rows = ((content.height / cell_h).ceil() as usize + 1).min(screen.height());
    let fit_cols = ((content.width / cell_w).ceil() as usize + 1).min(screen.width());

    unsafe {
        ctx.PushAxisAlignedClip(&clip, D2D1_ANTIALIAS_MODE_ALIASED);
        for row in 0..fit_rows {
            let line = top_line + row;
            for col in 0..fit_cols {
                let Some(cell) = screen.view_cell(row, col) else {
                    continue;
                };
                let is_cursor = cursor_visible && row == cursor_row && col == cursor_col;
                let is_selected = selection
                    .as_ref()
                    .is_some_and(|range| range_contains(range, line, col));
                let x = content.x + col as f32 * cell_w;
                let y = content.y + row as f32 * cell_h;
                let rect = D2D_RECT_F {
                    left: x,
                    top: y,
                    right: x + cell_w,
                    bottom: y + cell_h,
                };

                if is_cursor {
                    brush.SetColor(&cursor_color);
                    ctx.FillRectangle(&rect, brush);
                } else if is_selected {
                    brush.SetColor(&selection_color);
                    ctx.FillRectangle(&rect, brush);
                } else if let Some(bg) = cell.background {
                    brush.SetColor(&theme_cell_color(theme, bg));
                    ctx.FillRectangle(&rect, brush);
                }

                if cell.ch != ' ' && cell.ch != '\0' {
                    let fg = if is_cursor {
                        default_bg
                    } else {
                        match cell.foreground {
                            Some(color) => theme_cell_color(theme, color),
                            None => default_fg,
                        }
                    };
                    brush.SetColor(&fg);
                    let format = if cell.bold { text_format_bold } else { text_format };
                    let mut utf16_buf = [0u16; 2];
                    let utf16 = cell.ch.encode_utf16(&mut utf16_buf);
                    ctx.DrawText(
                        utf16,
                        format,
                        &rect,
                        brush,
                        D2D1_DRAW_TEXT_OPTIONS_NONE,
                        DWRITE_MEASURING_MODE_NATURAL,
                    );
                }
            }
        }
        ctx.PopAxisAlignedClip();
    }
}

/// Draw the left sidebar panel: a worklane list with active highlight + color
/// dots, indented pane rows with focus highlight, and a status pill per pane.
#[allow(clippy::too_many_arguments)]
unsafe fn draw_sidebar(
    ctx: &ID2D1DeviceContext,
    brush: &ID2D1SolidColorBrush,
    model: &SidebarModel,
    client_h: f32,
    text_format: &IDWriteTextFormat,
    text_format_bold: &IDWriteTextFormat,
    cell_w: f32,
    scale: f32,
) {
    unsafe {
        let width = model.width * scale;
        let row_h = SIDEBAR_ROW_H * scale;
        let pad = SIDEBAR_PAD * scale;
        let indent = SIDEBAR_PANE_INDENT * scale;
        let panel = D2D_RECT_F { left: 0.0, top: 0.0, right: width, bottom: client_h };
        brush.SetColor(&SIDEBAR_BG);
        ctx.FillRectangle(&panel, brush);
        let border = D2D_RECT_F { left: width - 1.0, top: 0.0, right: width, bottom: client_h };
        brush.SetColor(&SIDEBAR_BORDER);
        ctx.FillRectangle(&border, brush);

        ctx.PushAxisAlignedClip(&panel, D2D1_ANTIALIAS_MODE_ALIASED);
        let mut y = pad;
        for worklane in &model.worklanes {
            // Worklane header row (active = highlighted).
            if worklane.is_active {
                let row = D2D_RECT_F { left: 0.0, top: y, right: width, bottom: y + row_h };
                brush.SetColor(&SIDEBAR_ACTIVE_BG);
                ctx.FillRectangle(&row, brush);
            }
            // Color dot.
            let dot_color = worklane
                .color
                .map(|(r, g, b)| rgb(r, g, b))
                .unwrap_or(ACCENT);
            let dot = D2D_RECT_F {
                left: pad,
                top: y + row_h * 0.5 - 4.0 * scale,
                right: pad + 8.0 * scale,
                bottom: y + row_h * 0.5 + 4.0 * scale,
            };
            brush.SetColor(&dot_color);
            ctx.FillRoundedRectangle(
                &D2D1_ROUNDED_RECT { rect: dot, radiusX: 2.0 * scale, radiusY: 2.0 * scale },
                brush,
            );
            // Worklane title (bold).
            brush.SetColor(if worklane.is_active { &ACCENT } else { &DARK_FG });
            draw_row_text(
                ctx,
                brush,
                text_format_bold,
                &worklane.title,
                pad + 16.0 * scale,
                y,
                width - pad,
                row_h,
            );
            y += row_h;

            // Pane rows.
            for pane in &worklane.panes {
                if pane.focused {
                    let prow = D2D_RECT_F { left: 0.0, top: y, right: width, bottom: y + row_h };
                    brush.SetColor(&SIDEBAR_ROW_FOCUSED_BG);
                    ctx.FillRectangle(&prow, brush);
                }
                let (label, color) = status_pill_style(pane.status);
                // Use the measured (already DPI-scaled) cell advance so the pill
                // fits the label; only the fixed padding needs `scale`.
                let pill_w = label.chars().count() as f32 * cell_w + 14.0 * scale;
                brush.SetColor(if pane.focused { &DARK_FG } else { &SIDEBAR_DIM_FG });
                // The title's layout rect stops short of the pill so long
                // titles truncate instead of running underneath it.
                draw_row_text(
                    ctx,
                    brush,
                    text_format,
                    &pane.title,
                    indent,
                    y,
                    width - pill_w - pad * 2.0,
                    row_h,
                );
                draw_status_pill(
                    ctx, brush, text_format, label, color, pill_w, width, y, cell_w, scale,
                );
                y += row_h;
            }
            y += 6.0 * scale;
        }
        ctx.PopAxisAlignedClip();
    }
}

/// Draw a single line of sidebar text, vertically centered in its row and
/// clipped to its layout rect.
#[allow(clippy::too_many_arguments)]
unsafe fn draw_row_text(
    ctx: &ID2D1DeviceContext,
    brush: &ID2D1SolidColorBrush,
    format: &IDWriteTextFormat,
    text: &str,
    left: f32,
    row_top: f32,
    right: f32,
    row_h: f32,
) {
    let utf16: Vec<u16> = text.encode_utf16().collect();
    if utf16.is_empty() {
        return;
    }
    let rect = D2D_RECT_F {
        left,
        top: row_top,
        right: right.max(left),
        bottom: row_top + row_h,
    };
    unsafe {
        ctx.DrawText(
            &utf16,
            format,
            &rect,
            brush,
            D2D1_DRAW_TEXT_OPTIONS_CLIP,
            DWRITE_MEASURING_MODE_NATURAL,
        );
    }
}

/// Draw a right-aligned status pill (colored rounded rect + dark label).
#[allow(clippy::too_many_arguments)]
unsafe fn draw_status_pill(
    ctx: &ID2D1DeviceContext,
    brush: &ID2D1SolidColorBrush,
    format: &IDWriteTextFormat,
    label: &str,
    color: D2D1_COLOR_F,
    pill_w: f32,
    panel_width: f32,
    row_top: f32,
    cell_w: f32,
    scale: f32,
) {
    let pad = SIDEBAR_PAD * scale;
    let pill_h = 16.0 * scale;
    let top = row_top + (SIDEBAR_ROW_H * scale - pill_h) * 0.5;
    let pill = D2D_RECT_F {
        left: panel_width - pill_w - pad,
        top,
        right: panel_width - pad,
        bottom: top + pill_h,
    };
    unsafe {
        brush.SetColor(&color);
        ctx.FillRoundedRectangle(
            &D2D1_ROUNDED_RECT { rect: pill, radiusX: pill_h * 0.5, radiusY: pill_h * 0.5 },
            brush,
        );
        brush.SetColor(&SIDEBAR_BG);
        // Center the label horizontally in the pill using the measured advance.
        let text_w = label.chars().count() as f32 * cell_w;
        let inset = ((pill_w - text_w) * 0.5).max(0.0);
        let text_rect = D2D_RECT_F {
            left: pill.left + inset,
            top: pill.top,
            right: pill.right,
            bottom: pill.bottom,
        };
        let utf16: Vec<u16> = label.encode_utf16().collect();
        ctx.DrawText(
            &utf16,
            format,
            &text_rect,
            brush,
            D2D1_DRAW_TEXT_OPTIONS_CLIP,
            DWRITE_MEASURING_MODE_NATURAL,
        );
    }
}

/// Draw a single line of overlay text in a row.
unsafe fn draw_overlay_text(
    ctx: &ID2D1DeviceContext,
    brush: &ID2D1SolidColorBrush,
    format: &IDWriteTextFormat,
    text: &str,
    left: f32,
    top: f32,
    right: f32,
) {
    let utf16: Vec<u16> = text.encode_utf16().collect();
    if utf16.is_empty() {
        return;
    }
    let rect = D2D_RECT_F { left, top, right: right.max(left), bottom: top + 22.0 };
    unsafe {
        ctx.DrawText(
            &utf16,
            format,
            &rect,
            brush,
            D2D1_DRAW_TEXT_OPTIONS_NONE,
            DWRITE_MEASURING_MODE_NATURAL,
        );
    }
}

/// Dim the window and draw the active floating overlay.
unsafe fn draw_overlay(
    ctx: &ID2D1DeviceContext,
    brush: &ID2D1SolidColorBrush,
    overlay: &Overlay,
    client_w: f32,
    client_h: f32,
    text_format: &IDWriteTextFormat,
    text_format_bold: &IDWriteTextFormat,
) {
    unsafe {
        let scrim = D2D_RECT_F { left: 0.0, top: 0.0, right: client_w, bottom: client_h };
        brush.SetColor(&OVERLAY_SCRIM);
        ctx.FillRectangle(&scrim, brush);
        match overlay {
            Overlay::Palette(model) => {
                draw_command_palette(ctx, brush, model, client_w, client_h, text_format, text_format_bold)
            }
            Overlay::GlobalSearch(model) => {
                draw_global_search(ctx, brush, model, client_w, client_h, text_format, text_format_bold)
            }
        }
    }
}

/// Draw the command-palette panel: query row + filtered item list.
unsafe fn draw_command_palette(
    ctx: &ID2D1DeviceContext,
    brush: &ID2D1SolidColorBrush,
    model: &PaletteModel,
    client_w: f32,
    client_h: f32,
    text_format: &IDWriteTextFormat,
    text_format_bold: &IDWriteTextFormat,
) {
    const HEADER_H: f32 = 44.0;
    const ITEM_H: f32 = 38.0;
    const PAD: f32 = 14.0;
    let panel_w = (client_w * 0.6).clamp(440.0, 660.0);
    let panel_h = HEADER_H + model.items.len() as f32 * ITEM_H + PAD;
    let panel_x = (client_w - panel_w) * 0.5;
    let panel_y = client_h * 0.15;
    let panel = D2D_RECT_F { left: panel_x, top: panel_y, right: panel_x + panel_w, bottom: panel_y + panel_h };
    unsafe {
        brush.SetColor(&OVERLAY_PANEL_BG);
        ctx.FillRoundedRectangle(&D2D1_ROUNDED_RECT { rect: panel, radiusX: 10.0, radiusY: 10.0 }, brush);
        brush.SetColor(&OVERLAY_PANEL_BORDER);
        ctx.DrawRoundedRectangle(
            &D2D1_ROUNDED_RECT { rect: panel, radiusX: 10.0, radiusY: 10.0 },
            brush,
            1.0,
            None::<&ID2D1StrokeStyle>,
        );

        // Query row.
        brush.SetColor(&ACCENT);
        draw_overlay_text(ctx, brush, text_format_bold, ">", panel_x + PAD, panel_y + 11.0, panel_x + PAD + 16.0);
        let (query_text, query_color) = if model.query.is_empty() {
            ("Type a command…", &OVERLAY_SUBTLE_FG)
        } else {
            (model.query.as_str(), &DARK_FG)
        };
        brush.SetColor(query_color);
        draw_overlay_text(ctx, brush, text_format, query_text, panel_x + PAD + 22.0, panel_y + 11.0, panel_x + panel_w - PAD);
        let sep = D2D_RECT_F {
            left: panel_x + PAD,
            top: panel_y + HEADER_H - 1.0,
            right: panel_x + panel_w - PAD,
            bottom: panel_y + HEADER_H,
        };
        brush.SetColor(&OVERLAY_PANEL_BORDER);
        ctx.FillRectangle(&sep, brush);

        // Items.
        let mut y = panel_y + HEADER_H + 2.0;
        for item in &model.items {
            if item.selected {
                let row = D2D_RECT_F { left: panel_x + 6.0, top: y, right: panel_x + panel_w - 6.0, bottom: y + ITEM_H - 2.0 };
                brush.SetColor(&OVERLAY_SELECTED_BG);
                ctx.FillRoundedRectangle(&D2D1_ROUNDED_RECT { rect: row, radiusX: 6.0, radiusY: 6.0 }, brush);
            }
            brush.SetColor(if item.selected { &ACCENT } else { &DARK_FG });
            draw_overlay_text(ctx, brush, text_format_bold, &item.title, panel_x + PAD + 6.0, y + 4.0, panel_x + panel_w * 0.64);
            if !item.subtitle.trim().is_empty() {
                brush.SetColor(&OVERLAY_SUBTLE_FG);
                draw_overlay_text(ctx, brush, text_format, &item.subtitle, panel_x + PAD + 6.0, y + 19.0, panel_x + panel_w * 0.64);
            }
            if !item.category.trim().is_empty() {
                brush.SetColor(&OVERLAY_SUBTLE_FG);
                draw_overlay_text(ctx, brush, text_format, &item.category, panel_x + panel_w * 0.66, y + 4.0, panel_x + panel_w - PAD);
            }
            y += ITEM_H;
        }
    }
}

/// Draw the global-search panel: query + match position/count.
unsafe fn draw_global_search(
    ctx: &ID2D1DeviceContext,
    brush: &ID2D1SolidColorBrush,
    model: &SearchModel,
    client_w: f32,
    client_h: f32,
    text_format: &IDWriteTextFormat,
    text_format_bold: &IDWriteTextFormat,
) {
    const PAD: f32 = 14.0;
    let panel_w = (client_w * 0.5).clamp(360.0, 560.0);
    let panel_h = 70.0;
    let panel_x = (client_w - panel_w) * 0.5;
    let panel_y = client_h * 0.12;
    let panel = D2D_RECT_F { left: panel_x, top: panel_y, right: panel_x + panel_w, bottom: panel_y + panel_h };
    unsafe {
        brush.SetColor(&OVERLAY_PANEL_BG);
        ctx.FillRoundedRectangle(&D2D1_ROUNDED_RECT { rect: panel, radiusX: 10.0, radiusY: 10.0 }, brush);
        brush.SetColor(&OVERLAY_PANEL_BORDER);
        ctx.DrawRoundedRectangle(
            &D2D1_ROUNDED_RECT { rect: panel, radiusX: 10.0, radiusY: 10.0 },
            brush,
            1.0,
            None::<&ID2D1StrokeStyle>,
        );
        brush.SetColor(&ACCENT);
        draw_overlay_text(ctx, brush, text_format_bold, "Find", panel_x + PAD, panel_y + 10.0, panel_x + 70.0);
        brush.SetColor(if model.query.is_empty() { &OVERLAY_SUBTLE_FG } else { &DARK_FG });
        let query_text = if model.query.is_empty() { "Search all panes…" } else { model.query.as_str() };
        draw_overlay_text(ctx, brush, text_format, query_text, panel_x + 56.0, panel_y + 10.0, panel_x + panel_w - PAD);
        let count = match model.selected {
            Some(index) => format!("{} / {} matches", index + 1, model.total),
            None if model.total > 0 => format!("{} matches", model.total),
            None => "No matches".to_string(),
        };
        brush.SetColor(&OVERLAY_SUBTLE_FG);
        draw_overlay_text(ctx, brush, text_format, &count, panel_x + PAD, panel_y + 40.0, panel_x + panel_w - PAD);
    }
}

/// Create a D3D11 device, preferring a hardware driver and falling back to the
/// WARP software rasterizer. `D3D11_CREATE_DEVICE_BGRA_SUPPORT` is required for
/// Direct2D interop.
unsafe fn create_d3d_device() -> Result<ID3D11Device> {
    for driver in [D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_WARP] {
        let mut device: Option<ID3D11Device> = None;
        let result = unsafe {
            D3D11CreateDevice(
                None,
                driver,
                HMODULE::default(),
                D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                None,
                D3D11_SDK_VERSION,
                Some(&mut device),
                None,
                None,
            )
        };
        if result.is_ok()
            && let Some(device) = device
        {
            return Ok(device);
        }
    }
    // Final attempt surfaces the real error.
    let mut device: Option<ID3D11Device> = None;
    unsafe {
        D3D11CreateDevice(
            None,
            D3D_DRIVER_TYPE_WARP,
            HMODULE::default(),
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            None,
            D3D11_SDK_VERSION,
            Some(&mut device),
            None,
            None,
        )?
    };
    device.ok_or_else(|| windows::core::Error::from_hresult(E_FAIL))
}

/// Create a D2D target bitmap over the swapchain's back buffer (buffer 0).
unsafe fn create_target_bitmap(
    context: &ID2D1DeviceContext,
    swapchain: &IDXGISwapChain1,
) -> Result<ID2D1Bitmap1> {
    let back_buffer: IDXGISurface = unsafe { swapchain.GetBuffer(0)? };
    let props = D2D1_BITMAP_PROPERTIES1 {
        pixelFormat: D2D1_PIXEL_FORMAT {
            format: DXGI_FORMAT_B8G8R8A8_UNORM,
            alphaMode: D2D1_ALPHA_MODE_IGNORE,
        },
        dpiX: 96.0,
        dpiY: 96.0,
        bitmapOptions: D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
        colorContext: std::mem::ManuallyDrop::new(None),
    };
    unsafe { context.CreateBitmapFromDxgiSurface(&back_buffer, Some(&props)) }
}

/// Effective DPI for `hwnd`: the per-monitor DPI, or a forced value from the
/// `ZENTTY_SHOT_DPI` env var (screenshot tooling), defaulting to 96 (100%).
fn effective_dpi(hwnd: HWND) -> f32 {
    if let Ok(forced) = std::env::var("ZENTTY_SHOT_DPI")
        && let Ok(value) = forced.trim().parse::<f32>()
        && value >= 72.0
    {
        return value;
    }
    let dpi = unsafe { GetDpiForWindow(hwnd) };
    if dpi == 0 { 96.0 } else { dpi as f32 }
}

/// Build the grid normal + bold text formats plus the ellipsis-trimmed UI
/// normal + bold formats, and measure the cell, with the font scaled to `dpi`
/// (so 14 DIP renders at the correct physical pixel size).
unsafe fn build_formats(
    dwrite: &IDWriteFactory,
    dpi: f32,
) -> Result<(
    IDWriteTextFormat,
    IDWriteTextFormat,
    IDWriteTextFormat,
    IDWriteTextFormat,
    f32,
    f32,
)> {
    let font_size = FONT_SIZE_DIP * dpi / 96.0;
    let normal = unsafe { create_text_format(dwrite, DWRITE_FONT_WEIGHT_NORMAL, font_size)? };
    let bold = unsafe { create_text_format(dwrite, DWRITE_FONT_WEIGHT_BOLD, font_size)? };
    let ui = unsafe { create_text_format(dwrite, DWRITE_FONT_WEIGHT_NORMAL, font_size)? };
    let ui_bold = unsafe { create_text_format(dwrite, DWRITE_FONT_WEIGHT_BOLD, font_size)? };
    unsafe { enable_ellipsis_trimming(dwrite, &ui)? };
    unsafe { enable_ellipsis_trimming(dwrite, &ui_bold)? };
    let (cell_width, cell_height) = unsafe { measure_cell(dwrite, &normal)? };
    Ok((normal, bold, ui, ui_bold, cell_width, cell_height))
}

/// Enable character-granularity ellipsis trimming on a UI text format, so
/// over-long chrome text degrades to a trailing '…' instead of hard-clipping.
unsafe fn enable_ellipsis_trimming(
    dwrite: &IDWriteFactory,
    format: &IDWriteTextFormat,
) -> Result<()> {
    let sign = unsafe { dwrite.CreateEllipsisTrimmingSign(format)? };
    let trimming = DWRITE_TRIMMING {
        granularity: DWRITE_TRIMMING_GRANULARITY_CHARACTER,
        delimiter: 0,
        delimiterCount: 0,
    };
    unsafe { format.SetTrimming(&trimming, &sign) }
}

/// Create a monospace `IDWriteTextFormat`, picking the first installed family
/// from [`FONT_FALLBACK_CHAIN`] (falling back to the first entry if none of the
/// queried families resolve — DirectWrite then substitutes a system default).
unsafe fn create_text_format(
    dwrite: &IDWriteFactory,
    weight: windows::Win32::Graphics::DirectWrite::DWRITE_FONT_WEIGHT,
    font_size: f32,
) -> Result<IDWriteTextFormat> {
    let family = unsafe { first_installed_family(dwrite) }.unwrap_or(FONT_FALLBACK_CHAIN[0]);
    let family_w = wide(family);
    let locale_w = wide("en-us");
    let format = unsafe {
        dwrite.CreateTextFormat(
            PCWSTR(family_w.as_ptr()),
            None,
            weight,
            DWRITE_FONT_STYLE_NORMAL,
            DWRITE_FONT_STRETCH_NORMAL,
            font_size,
            PCWSTR(locale_w.as_ptr()),
        )?
    };
    // Single-line terminal rows: never wrap; vertically center each glyph in
    // its cell rect for even line rhythm.
    let _ = unsafe { format.SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP) };
    let _ = unsafe { format.SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER) };
    Ok(format)
}

/// Measure the monospace cell size (advance width, line height) in pixels by
/// laying out a single representative glyph with `format`.
unsafe fn measure_cell(
    dwrite: &IDWriteFactory,
    format: &IDWriteTextFormat,
) -> Result<(f32, f32)> {
    let glyph = wide("M");
    // Trailing NUL is excluded from the measured run.
    let layout: IDWriteTextLayout =
        unsafe { dwrite.CreateTextLayout(&glyph[..1], format, 4096.0, 4096.0)? };
    let mut m = DWRITE_TEXT_METRICS::default();
    unsafe { layout.GetMetrics(&mut m)? };
    let width = if m.widthIncludingTrailingWhitespace > 0.0 {
        m.widthIncludingTrailingWhitespace
    } else {
        FONT_SIZE_DIP * 0.6
    };
    let height = if m.height > 0.0 {
        m.height
    } else {
        FONT_SIZE_DIP * 1.3
    };
    Ok((width, height))
}

/// Return the first family in [`FONT_FALLBACK_CHAIN`] present in the system
/// font collection, or `None` if the collection is unavailable / none match.
unsafe fn first_installed_family(dwrite: &IDWriteFactory) -> Option<&'static str> {
    let mut collection: Option<IDWriteFontCollection> = None;
    unsafe { dwrite.GetSystemFontCollection(&mut collection, false) }.ok()?;
    let collection = collection?;
    for family in FONT_FALLBACK_CHAIN {
        let name = wide(family);
        let mut index = 0u32;
        let mut exists = windows::core::BOOL(0);
        if unsafe { collection.FindFamilyName(PCWSTR(name.as_ptr()), &mut index, &mut exists) }
            .is_ok()
            && exists.as_bool()
        {
            return Some(family);
        }
    }
    None
}

/// Current client-area size of `hwnd` in physical pixels.
fn client_pixel_size(hwnd: HWND) -> (u32, u32) {
    let mut rect = RECT::default();
    if unsafe { GetClientRect(hwnd, &mut rect) }.is_ok() {
        let width = (rect.right - rect.left).max(0) as u32;
        let height = (rect.bottom - rect.top).max(0) as u32;
        (width, height)
    } else {
        (0, 0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_pill_style_distinguishes_states() {
        let (ready_label, ready_color) = status_pill_style(PaneStatusKind::Ready);
        let (working_label, working_color) = status_pill_style(PaneStatusKind::Working);
        let (idle_label, idle_color) = status_pill_style(PaneStatusKind::Idle);

        assert_eq!(ready_label, "Ready");
        assert_eq!(working_label, "Working");
        assert_eq!(idle_label, "Idle");

        // Each of the three states has a distinct color.
        let colors = [ready_color, working_color, idle_color];
        for i in 0..colors.len() {
            for j in (i + 1)..colors.len() {
                assert!(
                    colors[i].r != colors[j].r
                        || colors[i].g != colors[j].g
                        || colors[i].b != colors[j].b,
                    "status colors must differ"
                );
            }
        }
    }
}
