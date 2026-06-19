//! core/mod.rs — installer-core for the Rust vertical.
//!
//! Ported from Swift MootInstallerCore piece by piece as each subcommand
//! comes online. paths is the foundation; client registry, config merge,
//! permissions, picker, and service backends land next.

pub mod clients;
pub mod daemon_client;
pub mod depth;
pub mod merge;
pub mod paths;
pub mod permissions;
pub mod release;
pub mod service;
