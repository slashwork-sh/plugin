//! Shared core for the slashwork offload network.
//!
//! One cross-platform Rust implementation of the offload protocol, so every
//! harness adapter (Claude Code, OpenClaw, Hermes) shares the exact same
//! answer to "when unsure, run locally." The `main.rs` binary exposes it as
//! `slashwork-offload <route|login|claim|submit>`; adapters shell out over
//! JSON on stdin/stdout and stay thin.
//!
//! The classifier ([`classify`]) decides whether a spawn is routable; the
//! dispatch state machine ([`dispatch`]) posts a routable task and waits out the
//! claim window and deadline. Both are pure. The real HTTP client that drives
//! dispatch lives in [`http`]. See `docs/openclaw-hermes-hooks.md` in the
//! coordinator repo for the full design.

pub mod bundle;
pub mod classify;
pub mod dispatch;
pub mod earn;
pub mod hook;
pub mod http;
