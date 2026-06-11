use crate::{
    clean_copy::CleanCopyPipeline, screen::TerminalScreen, selection::TerminalSelection,
    shell::ShellEscaping,
};

pub const MAX_CLIPBOARD_IMAGE_SIZE: usize = 10 * 1024 * 1024;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClipboardImage {
    pub escaped_path: String,
    pub byte_len: usize,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct TerminalClipboardInput {
    text: Option<String>,
    file_paths: Vec<String>,
    image: Option<ClipboardImage>,
}

impl TerminalClipboardInput {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_text(mut self, text: impl Into<String>) -> Self {
        self.text = Some(text.into());
        self
    }

    pub fn with_file_path(mut self, path: impl Into<String>) -> Self {
        self.file_paths.push(path.into());
        self
    }

    pub fn with_image(mut self, image: ClipboardImage) -> Self {
        self.image = Some(image);
        self
    }

    pub fn pasted_string(&self) -> Option<String> {
        if !self.file_paths.is_empty() {
            return None;
        }
        self.text.clone()
    }

    pub fn pasted_content(&self) -> Option<TerminalClipboardPaste> {
        if !self.file_paths.is_empty() {
            let escaped = self
                .file_paths
                .iter()
                .map(|path| ShellEscaping::escape_path(path))
                .collect::<Vec<_>>()
                .join(" ");
            return Some(TerminalClipboardPaste::FilePath(escaped));
        }

        if let Some(text) = &self.text {
            return Some(TerminalClipboardPaste::Text(text.clone()));
        }

        let image = self.image.as_ref()?;
        if image.byte_len > MAX_CLIPBOARD_IMAGE_SIZE {
            return None;
        }
        Some(TerminalClipboardPaste::FilePath(image.escaped_path.clone()))
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TerminalClipboardPaste {
    Text(String),
    FilePath(String),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TerminalClipboardContent {
    pub text: String,
    pub was_cleaned: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TerminalCopyMode {
    Raw,
    Clean,
    Auto {
        is_auto_clean_enabled: bool,
        suppress_callback_cleaning: bool,
    },
}

pub struct TerminalCopyPlanner;

impl TerminalCopyPlanner {
    pub fn copy_selection(
        screen: &TerminalScreen,
        selection: &TerminalSelection,
        mode: TerminalCopyMode,
    ) -> Option<TerminalClipboardContent> {
        let raw = selection.selected_text(screen)?;
        Some(plan_copy_text(&raw, mode))
    }
}

fn plan_copy_text(raw: &str, mode: TerminalCopyMode) -> TerminalClipboardContent {
    let should_clean = match mode {
        TerminalCopyMode::Raw => false,
        TerminalCopyMode::Clean => true,
        TerminalCopyMode::Auto {
            is_auto_clean_enabled,
            suppress_callback_cleaning,
        } => CleanCopyPipeline::should_clean_terminal_copy_action(
            is_auto_clean_enabled,
            suppress_callback_cleaning,
        ),
    };

    if should_clean {
        let result = CleanCopyPipeline::clean(raw);
        TerminalClipboardContent {
            text: result.text,
            was_cleaned: result.was_modified,
        }
    } else {
        TerminalClipboardContent {
            text: raw.to_string(),
            was_cleaned: false,
        }
    }
}
