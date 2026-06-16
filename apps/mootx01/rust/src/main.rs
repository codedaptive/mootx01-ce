//! mootx01 binary — thin shell over the library.
//!
//! All logic lives in mootx01_cli (parse, dispatch, commands) so tests
//! exercise the full path without spawning a process. This file only:
//! collects argv, parses, dispatches, and maps results onto exit codes
//! per spec §5 (0 success, 1 operational failure, 64 usage).

use std::process::ExitCode;

use mootx01_cli::cli::{self, Command};
use mootx01_cli::commands;
use mootx01_cli::exit;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();

    let command = match cli::parse(&args) {
        Ok(c) => c,
        Err(e) => {
            // Usage errors print to stderr and exit 64 (§5). The bare
            // invocation carries the root usage text as its message (§2).
            eprintln!("{e}");
            return ExitCode::from(exit::USAGE);
        }
    };

    match command {
        Command::Version => {
            println!("{}", mootx01_cli::CURRENT_VERSION);
            ExitCode::from(exit::OK)
        }
        Command::Help => {
            println!("{}", cli::root_usage());
            ExitCode::from(exit::OK)
        }
        Command::HelpFor(sub) => {
            println!("{}", cli::subcommand_usage(sub));
            ExitCode::from(exit::OK)
        }
        other => commands::dispatch(other),
    }
}
