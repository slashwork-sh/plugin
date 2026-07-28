//! `slashwork-offload` CLI: the one binary every harness adapter shells out to.
//!
//! `route` is the whole offload path: read the spawn envelope on stdin, classify
//! it, and on a routable class post the task and wait out the claim window and
//! deadline, printing the decision on stdout. The iron rule from `intercept.sh`
//! holds: `route` always exits 0, and any missing token, bad base URL, unroutable
//! prompt, cold pool, or network error resolves to a local spawn, never a hang
//! and never worse.
//!
//! `login`, `claim`, and `submit` (the earner side) are the next increment; they
//! are recognized but not yet implemented.

use offload::classify::{classify, Decision};
use offload::dispatch::{dispatch, RouteOutcome};
use offload::http::{resolve_base, resolve_token, UreqCoordinator};
use serde::Deserialize;
use std::io::Read;

/// The route envelope an adapter sends. Unknown fields (`harness`, `tool_name`,
/// `cwd`) are ignored: the classifier only needs the prompt.
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
                "slashwork-offload {cmd}: not yet implemented (next increment: the earner side)"
            );
            std::process::exit(1);
        }
        _ => {
            eprintln!("usage: slashwork-offload <route|login|claim|submit>");
            std::process::exit(2);
        }
    }
}

/// Read the spawn envelope, classify it, and dispatch a routable one. Always
/// exits 0; every non-artifact path prints a `local` decision.
fn cmd_route() -> ! {
    let mut buf = String::new();
    if std::io::stdin().read_to_string(&mut buf).is_err() {
        emit_local("could not read route input");
    }
    let input: RouteInput = serde_json::from_str(&buf).unwrap_or_default();

    // Token and base first (like the hook): without them, or with a non-https
    // base, the token cannot leave, so run local before classifying.
    let Some(token) = resolve_token() else {
        emit_local("no slashwork token");
    };
    let Some(base) = resolve_base() else {
        emit_local("base url is not https");
    };

    match classify(&input.spawn.prompt) {
        Decision::Local { reason } => emit_local(&reason),
        Decision::Routable { class } => {
            let coord = UreqCoordinator::new(base, token);
            match dispatch(&coord, class, &input.spawn.prompt) {
                RouteOutcome::Local { reason } => emit_local(&reason),
                RouteOutcome::Artifact {
                    task_id,
                    class,
                    artifact,
                } => {
                    println!(
                        "{}",
                        serde_json::json!({
                            "decision": "artifact",
                            "task_id": task_id,
                            "class": class.as_str(),
                            "artifact": artifact.artifact,
                            "tokens_used": artifact.tokens_used,
                            "settled": artifact.settled,
                            "tokens_saved_total": artifact.tokens_saved_total,
                        })
                    );
                    std::process::exit(0);
                }
            }
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
