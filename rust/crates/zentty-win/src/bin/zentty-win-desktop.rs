// GUI app: no console window. Note this makes `--help`/error output invisible
// when launched from a shell; the flags are documented in the README.
#![cfg_attr(windows, windows_subsystem = "windows")]

use std::process::ExitCode;

use zentty_win::desktop::{DesktopShellConfig, DesktopShellConfigError, run_desktop, usage};

fn main() -> ExitCode {
    let config = match DesktopShellConfig::parse(std::env::args().skip(1)) {
        Ok(config) => config,
        Err(DesktopShellConfigError::HelpRequested) => {
            println!("{}", usage());
            return ExitCode::SUCCESS;
        }
        Err(error) => {
            eprintln!("{error}");
            eprintln!("{}", usage());
            show_fatal_error(&format!("{error}\n\n{}", usage()));
            return ExitCode::from(2);
        }
    };

    match run_desktop(config) {
        Ok(code) => ExitCode::from(u8::try_from(code).unwrap_or(1)),
        Err(error) => {
            eprintln!("{error}");
            show_fatal_error(&error.to_string());
            ExitCode::from(1)
        }
    }
}

/// Startup failures must be visible: the binary is a GUI app
/// (`windows_subsystem = "windows"`), so stderr goes nowhere when launched
/// from the Start menu or Explorer.
#[cfg(windows)]
fn show_fatal_error(message: &str) {
    use windows::Win32::UI::WindowsAndMessaging::{MB_ICONERROR, MB_OK, MessageBoxW};
    use windows::core::PCWSTR;
    let text: Vec<u16> = message.encode_utf16().chain(std::iter::once(0)).collect();
    let caption: Vec<u16> = "Zentty".encode_utf16().chain(std::iter::once(0)).collect();
    unsafe {
        MessageBoxW(
            None,
            PCWSTR(text.as_ptr()),
            PCWSTR(caption.as_ptr()),
            MB_OK | MB_ICONERROR,
        );
    }
}

#[cfg(not(windows))]
fn show_fatal_error(_message: &str) {}
