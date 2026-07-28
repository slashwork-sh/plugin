//! Shared core for the slashwork offload network.
//!
//! One cross-platform Rust implementation of the offload protocol, so every
//! harness adapter (Claude Code, OpenClaw, Hermes) shares the exact same
//! answer to "when unsure, run locally." The `main.rs` binary exposes it as
//! `slashwork-offload <route|login|claim|submit>`; adapters shell out over
//! JSON on stdin/stdout and stay thin.
//!
//! v1 ships the classifier (this module). The network protocol (POST
//! `/api/tasks`, the claim window, and the deadline long-poll) is the next
//! build-order increment; see `docs/openclaw-hermes-hooks.md` in the
//! coordinator repo.

pub mod classify;
