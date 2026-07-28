//! `slashwork-offload` CLI: the one binary every harness adapter shells out to.
//!
//! v1 implements `route`'s classifier half. Adapters pipe the spawn envelope in
//! as JSON on stdin and read the decision back on stdout. The iron rule from
//! `intercept.sh` holds: `route` always exits 0, and any read, parse, or (later)
//! network failure resolves to a local spawn, never a hang and never worse.
//!
//! The network protocol (`route` dispatch, `login`, `claim`, `submit`) is the
//! next build-order increment; those subcommands are recognized but not yet
//! implemented.

use offload::classify::{classify, Decision};
use serde::Deserialize;
use std::io::Read;

/// The route envelope an adapter sends. Unknown fields (`harness`, `tool_name`,
/// `cwd`) are ignored: the v1 classifier only needs the prompt.
#[derive(Deserialize, Default)]
struct RouteInput {
    #[serde(default)]
    spawn: Spawn,
}

#[derive(Deserialize, Default)]
struct Spawn {
    #[serde(default)]
    prompt: String,
}

fn main() {
    match std::env::args().nth(1).as_deref() {
        Some("route") => cmd_route(),
        Some(cmd @ ("login" | "claim" | "submit")) => {
            eprintln!(
                "slashwork-offload {cmd}: not yet implemented (next increment: the network protocol)"
            );
            std::process::exit(1);
        }
        _ => {
            eprintln!("usage: slashwork-offload <route|login|claim|submit>");
            std::process::exit(2);
        }
    }
}

/// Read the spawn envelope, classify it, and print the decision. Always exits 0.
fn cmd_route() -> ! {
    let mut buf = String::new();
    if std::io::stdin().read_to_string(&mut buf).is_err() {
        emit_local("could not read route input");
    }
    let input: RouteInput = serde_json::from_str(&buf).unwrap_or_default();

    match classify(&input.spawn.prompt) {
        Decision::Local { reason } => emit_local(&reason),
        Decision::Routable { class } => {
            // Dispatch (POST /api/tasks, the claim window, the deadline
            // long-poll, and the artifact wrapper) is the next increment. Until
            // it lands, the safe, invariant-preserving behavior is a local
            // spawn, tagged with the class the classifier chose so the roadmap
            // is visible in the output rather than silently swallowed.
            emit_local(&format!(
                "routing not yet implemented (classified {})",
                class.as_str()
            ));
        }
    }
}

/// Print a `local` decision to stdout and exit 0.
fn emit_local(reason: &str) -> ! {
    println!(
        "{}",
        serde_json::json!({ "decision": "local", "reason": reason })
    );
    std::process::exit(0);
}
