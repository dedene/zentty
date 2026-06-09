use crate::clipboard::TerminalClipboardPaste;

const BRACKETED_PASTE_START: &[u8] = b"\x1b[200~";
const BRACKETED_PASTE_END: &[u8] = b"\x1b[201~";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TerminalPasteMode {
    Plain,
    Bracketed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TerminalInputAction {
    Bytes(Vec<u8>),
    ReturnKey,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TerminalInputPayload {
    actions: Vec<TerminalInputAction>,
}

impl TerminalInputPayload {
    pub fn actions(&self) -> &[TerminalInputAction] {
        &self.actions
    }

    pub fn into_pty_bytes(self) -> Vec<u8> {
        let mut bytes = Vec::new();
        for action in self.actions {
            match action {
                TerminalInputAction::Bytes(chunk) => bytes.extend(chunk),
                TerminalInputAction::ReturnKey => bytes.push(b'\r'),
            }
        }
        bytes
    }
}

pub struct TerminalInputPlanner;

impl TerminalInputPlanner {
    pub fn paste_payload(
        paste: &TerminalClipboardPaste,
        mode: TerminalPasteMode,
    ) -> TerminalInputPayload {
        TerminalInputPayload {
            actions: vec![TerminalInputAction::Bytes(paste_bytes(
                paste_content(paste),
                mode,
            ))],
        }
    }

    pub fn submit_command(command: &str, mode: TerminalPasteMode) -> TerminalInputPayload {
        TerminalInputPayload {
            actions: vec![
                TerminalInputAction::Bytes(paste_bytes(command, mode)),
                TerminalInputAction::ReturnKey,
            ],
        }
    }
}

fn paste_content(paste: &TerminalClipboardPaste) -> &str {
    match paste {
        TerminalClipboardPaste::Text(text) => text,
        TerminalClipboardPaste::FilePath(path) => path,
    }
}

fn paste_bytes(text: &str, mode: TerminalPasteMode) -> Vec<u8> {
    match mode {
        TerminalPasteMode::Plain => text.as_bytes().to_vec(),
        TerminalPasteMode::Bracketed => {
            let mut bytes = Vec::with_capacity(
                BRACKETED_PASTE_START.len() + text.len() + BRACKETED_PASTE_END.len(),
            );
            bytes.extend(BRACKETED_PASTE_START);
            bytes.extend(text.as_bytes());
            bytes.extend(BRACKETED_PASTE_END);
            bytes
        }
    }
}
