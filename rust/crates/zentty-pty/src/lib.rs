pub mod native;

use std::collections::BTreeMap;
use std::error::Error;
use std::fmt;
use std::time::Duration;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TerminalSize {
    pub cols: u16,
    pub rows: u16,
    pub pixel_width: u16,
    pub pixel_height: u16,
}

impl TerminalSize {
    pub fn new(cols: u16, rows: u16) -> Self {
        Self {
            cols: cols.max(1),
            rows: rows.max(1),
            pixel_width: 0,
            pixel_height: 0,
        }
    }

    pub fn with_cell_pixels(mut self, cell_width: u16, cell_height: u16) -> Self {
        self.pixel_width = self.cols.saturating_mul(cell_width);
        self.pixel_height = self.rows.saturating_mul(cell_height);
        self
    }
}

impl Default for TerminalSize {
    fn default() -> Self {
        Self::new(80, 24)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PtySessionRequest {
    program: String,
    args: Vec<String>,
    env: BTreeMap<String, String>,
    cwd: Option<String>,
}

impl PtySessionRequest {
    pub fn new(program: impl Into<String>) -> Self {
        Self {
            program: program.into(),
            args: Vec::new(),
            env: BTreeMap::new(),
            cwd: None,
        }
    }

    pub fn arg(mut self, arg: impl Into<String>) -> Self {
        self.args.push(arg.into());
        self
    }

    pub fn extend_args<I, S>(mut self, args: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.args.extend(args.into_iter().map(Into::into));
        self
    }

    pub fn env(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.env.insert(key.into(), value.into());
        self
    }

    pub fn cwd(mut self, cwd: impl Into<String>) -> Self {
        self.cwd = Some(cwd.into());
        self
    }

    pub fn validate(&self) -> Result<(), PtyError> {
        if self.program.trim().is_empty() {
            return Err(PtyError::InvalidProgram);
        }

        if let Some(key) = self.env.keys().find(|key| key.trim().is_empty()) {
            return Err(PtyError::InvalidEnvironmentKey(key.clone()));
        }

        Ok(())
    }

    pub fn program(&self) -> &str {
        &self.program
    }

    pub fn args(&self) -> &[String] {
        &self.args
    }

    pub fn environment(&self) -> &BTreeMap<String, String> {
        &self.env
    }

    pub fn working_directory(&self) -> Option<&String> {
        self.cwd.as_ref()
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PtyProcessOutput {
    pub status_success: bool,
    pub exit_code: Option<u32>,
    pub output: String,
}

#[derive(Debug)]
pub enum PtyError {
    InvalidProgram,
    InvalidEnvironmentKey(String),
    OutputReaderAlreadyTaken,
    InputWriterAlreadyTaken,
    OutputTimeout { timeout: Duration, output: String },
    Io(std::io::Error),
    Backend(String),
}

impl fmt::Display for PtyError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PtyError::InvalidProgram => write!(formatter, "PTY program must not be empty"),
            PtyError::InvalidEnvironmentKey(key) => {
                write!(formatter, "PTY environment key must not be empty: {key:?}")
            }
            PtyError::OutputReaderAlreadyTaken => {
                write!(formatter, "PTY output reader has already been taken")
            }
            PtyError::InputWriterAlreadyTaken => {
                write!(formatter, "PTY input writer has already been taken")
            }
            PtyError::OutputTimeout { timeout, output } => {
                if !output.is_empty() {
                    return write!(
                        formatter,
                        "PTY command did not finish within {timeout:?}; partial output: {output:?}"
                    );
                }
                write!(formatter, "PTY command did not finish within {timeout:?}")
            }
            PtyError::Io(error) => write!(formatter, "{error}"),
            PtyError::Backend(error) => write!(formatter, "{error}"),
        }
    }
}

impl Error for PtyError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            PtyError::Io(error) => Some(error),
            _ => None,
        }
    }
}

impl From<std::io::Error> for PtyError {
    fn from(error: std::io::Error) -> Self {
        PtyError::Io(error)
    }
}

impl From<anyhow::Error> for PtyError {
    fn from(error: anyhow::Error) -> Self {
        PtyError::Backend(error.to_string())
    }
}
