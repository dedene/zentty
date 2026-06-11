use std::io;
use std::process::ExitCode;

use zentty_win::host::{
    HostConfig, HostConfigError, run_agent_ipc_cli, run_interactive, run_scripted,
    run_workspace_interactive, usage,
};

fn main() -> ExitCode {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if args.first().is_some_and(|arg| arg == "ipc") {
        return match run_agent_ipc_cli(args.into_iter().skip(1), &mut io::stdout()) {
            Ok(code) => ExitCode::from(u8::try_from(code).unwrap_or(1)),
            Err(error) => {
                eprintln!("{error}");
                ExitCode::from(1)
            }
        };
    }
    if args.first().is_some_and(|arg| arg == "server") {
        return match run_agent_ipc_cli(args, &mut io::stdout()) {
            Ok(code) => ExitCode::from(u8::try_from(code).unwrap_or(1)),
            Err(error) => {
                eprintln!("{error}");
                ExitCode::from(1)
            }
        };
    }

    let config = match HostConfig::parse(args) {
        Ok(config) => config,
        Err(HostConfigError::HelpRequested) => {
            println!("{}", usage());
            return ExitCode::SUCCESS;
        }
        Err(error) => {
            eprintln!("{error}");
            eprintln!("{}", usage());
            return ExitCode::from(2);
        }
    };

    let command_supplied = config.command_supplied;
    let workspace_supplied = config.workspace_path.is_some();
    let result = if workspace_supplied {
        run_workspace_interactive(config, io::stdin(), io::stdout(), None)
    } else if command_supplied {
        run_scripted(config, &mut io::stdout())
    } else {
        run_interactive(config, io::stdin(), io::stdout(), None)
    };

    match result {
        Ok(code) => ExitCode::from(u8::try_from(code).unwrap_or(1)),
        Err(error) => {
            eprintln!("{error}");
            ExitCode::from(1)
        }
    }
}
