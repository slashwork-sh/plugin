//! `slashwork-offload` CLI: the one binary every harness adapter shells out to.
//!
//! - `route`: the offloader path. Classify a spawn and, if routable, post it and
//!   wait out the claim window and deadline. Always exits 0, falling back to a
//!   local spawn on any failure.
//! - `hook`: the whole Claude Code `PreToolUse` path, raw envelope in, hook JSON
//!   out. `route` plus the envelope parsing, consent gate, savings receipt, and
//!   decision shaping the shell hook used to do with `jq`.
//! - `classify`: the classifier verdict alone, no network. A harness hook calls
//!   it to decide whether to show its one-time consent disclosure before the
//!   first routable spawn.
//! - `login`: the CLI browser auth flow; writes `~/.slashwork/token`.
//! - `claim`: hold the queue feed open and claim the next task; prints the job.
//! - `submit`: post an artifact (read from stdin) for a claimed task.
//! - `goal`: parse an earn goal (`90s`, `30m`, `200cr`) into the plan an
//!   adapter's earn loop runs to. Offline.
//! - `credits`: the signed-in earner's credit balance, for measuring a credits
//!   goal against its baseline.
//!
//! Adapters pipe JSON over stdin/stdout and stay thin.

use offload::classify::{classify, Decision};
use offload::dispatch::{dispatch, wrap_artifact, RouteOutcome};
use offload::earn::{
    claim_outcome, credits_balance, login_poll, parse_goal, submit_outcome, ClaimOutcome, Goal,
    LoginPoll, SseTaskScanner, SubmitOutcome, CREDITS_GOAL_CEILING_SECS,
};
use offload::hook::{
    consent_marker, is_self_worker, receipt, record_saving, render_plot, route_log, Envelope,
};
use offload::http::{
    fetch_me, home_dir, login_poll_once, login_start, post_claim, probe_auth, resolve_base,
    resolve_token, stream_queue, submit_task, LineAction, UreqCoordinator,
};
use serde::Deserialize;
use serde_json::Value;
use std::io::Read;
use std::time::{Duration, Instant};

// Exit codes shared across the earner subcommands.
const EXIT_FAIL: i32 = 1;
const EXIT_USAGE: i32 = 2;
const EXIT_AUTH: i32 = 3;
const EXIT_TIMEOUT: i32 = 4;
const EXIT_BASE: i32 = 5;

/// The route envelope an adapter sends. `tool_name` and `cwd` are ignored (the
/// classifier only needs the prompt); `harness` is forwarded to the coordinator.
#[derive(Deserialize, Default)]
struct RouteInput {
    #[serde(default)]
    spawn: Spawn,
    /// Which harness is routing this spawn (the adapter sets it). Forwarded so
    /// the coordinator attributes the task; absent posts no harness.
    #[serde(default)]
    harness: Option<String>,
}

#[derive(Deserialize, Default)]
struct Spawn {
    #[serde(default)]
    prompt: String,
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("route") => cmd_route(),
        Some("hook") => cmd_hook(),
        Some("classify") => cmd_classify(),
        Some("login") => cmd_login(),
        Some("claim") => cmd_claim(&args[1..]),
        Some("submit") => cmd_submit(&args[1..]),
        Some("goal") => cmd_goal(&args[1..]),
        Some("credits") => cmd_credits(),
        _ => {
            eprintln!(
                "usage: slashwork-offload <route|hook|classify|login|claim|submit|goal|credits>"
            );
            std::process::exit(EXIT_USAGE);
        }
    }
}

// --- route (offloader) ---

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
            let coord = UreqCoordinator::new(base, token, input.harness);
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
                            // The untrusted-content-wrapped artifact the adapter
                            // hands to its parent model verbatim (invariant 2).
                            "wrapped": wrap_artifact(&artifact.artifact),
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

// --- hook (Claude Code PreToolUse, end to end) ---

/// `hook`: the whole Claude Code `PreToolUse` path, from the raw envelope on stdin
/// to the hook JSON on stdout.
///
/// The shell hook is a shim around this. Everything it used to do with `jq`
/// (parse the envelope, hold the consent marker, keep the savings log, render
/// the receipt, shape the `deny`) happens here, so routing depends on nothing
/// but this binary. `jq` is absent from Git Bash, which is why the offloader was
/// inert on Windows even once a binary was installed.
///
/// Always exits 0. Printing nothing lets Claude Code spawn the subagent
/// normally, which is the outcome for every path except a returned artifact.
fn cmd_hook() -> ! {
    let mut buf = String::new();
    if std::io::stdin().read_to_string(&mut buf).is_err() {
        std::process::exit(0);
    }
    let env = Envelope::parse(&buf);

    // Not a subagent spawn, or nothing to route: silent local.
    if !env.is_subagent_spawn() || env.tool_input.prompt.is_empty() {
        std::process::exit(0);
    }
    let prompt = &env.tool_input.prompt;

    // Our own earner worker spawns are never reposted.
    if is_self_worker(prompt) {
        std::process::exit(0);
    }

    // Token presence gates whether the hook acts at all, and so whether the user
    // ever sees the disclosure. The real calls resolve the token again below.
    if resolve_token().is_none() {
        std::process::exit(0);
    }
    let Some(base) = resolve_base() else {
        std::process::exit(0);
    };

    // First-candidate consent gate, once per user. Installing the plugin and
    // signing in is the standing consent, but nothing leaves the machine before
    // the user has seen what routing does: their first *routable* spawn prints
    // the disclosure and still runs locally. Classify without a token or a
    // network call, so a spawn that was never routable neither triggers the
    // notice nor spends the one disclosure.
    let marker = consent_marker(&env.session_key());
    if !marker.exists() {
        match classify(prompt) {
            Decision::Routable { class } => {
                route_log("routed", class.as_str());
                let _ = std::fs::write(&marker, b"");
                // systemMessage, not stderr: an exit-0 hook's stderr shows only
                // in verbose mode, and a disclosure the user cannot see is not a
                // disclosure. No decision attached, so the spawn runs locally.
                emit(&serde_json::json!({ "systemMessage": CONSENT_NOTICE }));
            }
            Decision::Local { reason } => route_log("local", &reason),
        }
        std::process::exit(0);
    }

    // Dispatch. The core classifies, posts, waits out the claim window and class
    // deadline, and cancels with a refund on any fall-through.
    let class = match classify(prompt) {
        Decision::Routable { class } => class,
        Decision::Local { reason } => {
            route_log("local", &reason);
            std::process::exit(0);
        }
    };
    let coord = UreqCoordinator::new(
        base,
        resolve_token().unwrap_or_default(),
        Some(HARNESS.into()),
    );
    match dispatch(&coord, class, prompt) {
        RouteOutcome::Artifact {
            class, artifact, ..
        } => {
            route_log("routed", class.as_str());
            let recent = record_saving(artifact.tokens_used);
            let plot = render_plot(&recent);
            let message = receipt(
                artifact.tokens_used,
                artifact.settled,
                artifact.tokens_saved_total,
                &plot,
            );
            // The deny is what hands the artifact back in place of the spawn.
            // Its reason is the core's untrusted-content-wrapped artifact
            // (invariant 2), so every harness and the acceptance judge agree on
            // the wrapper.
            emit(&serde_json::json!({
                "systemMessage": message,
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": wrap_artifact(&artifact.artifact),
                }
            }));
            std::process::exit(0);
        }
        RouteOutcome::Local { reason } => {
            route_log("local", &reason);
            // Out of credits is the one rejection the user can act on, so it
            // gets a visible notice. Everything else stays quiet: the spawn just
            // runs locally, as it always did.
            if reason.contains("not enough credits") {
                emit(&serde_json::json!({
                    "systemMessage": format!(
                        "slashwork: {reason}. This task ran locally. \
                         Run /earn to earn credits by running tasks for others."
                    )
                }));
            }
            std::process::exit(0);
        }
    }
}

/// The harness tag the coordinator attributes routed tasks to.
const HARNESS: &str = "claude-code";

/// Shown once per user, before their first routable spawn is ever routed.
const CONSENT_NOTICE: &str = "slashwork intercept is on: self-contained subagent tasks will be routed to the offload network, meaning the task prompt is sent to another slashwork user's session to run. This first task runs locally; routing starts with the next one. Run /work off (or set SLASHWORK_INTERCEPT=0) to stop routing.";

/// Print one compact JSON object for Claude Code to read.
fn emit(v: &serde_json::Value) {
    println!("{v}");
}

// --- classify (offloader consent gate) ---

/// Read the spawn envelope and print only the classifier's verdict, no token, no
/// network: `{"decision":"routable","class":…}` or `{"decision":"local","reason":…}`.
/// The Claude Code hook calls this to decide whether to show its one-time consent
/// disclosure before the first routable spawn of a session. Always exits 0.
fn cmd_classify() -> ! {
    let mut buf = String::new();
    if std::io::stdin().read_to_string(&mut buf).is_err() {
        emit_local("could not read classify input");
    }
    let input: RouteInput = serde_json::from_str(&buf).unwrap_or_default();
    match classify(&input.spawn.prompt) {
        // A local verdict is shaped exactly like `route`'s, so reuse the emitter.
        Decision::Local { reason } => emit_local(&reason),
        Decision::Routable { class } => {
            println!(
                "{}",
                serde_json::json!({ "decision": "routable", "class": class.as_str() })
            );
            std::process::exit(0);
        }
    }
}

// --- goal / credits (shared earn-loop plumbing) ---

/// `goal <spec>`: parse an earn goal and print the plan an adapter's loop runs
/// to. Pure and offline, so every harness reads `90s` / `30m` / `200cr` the same
/// way instead of each adapter growing its own parser.
fn cmd_goal(rest: &[String]) -> ! {
    let spec = rest.join(" ");
    match parse_goal(&spec) {
        Some(Goal::Time { seconds }) => {
            println!(
                "{}",
                serde_json::json!({ "mode": "time", "seconds": seconds })
            );
            std::process::exit(0);
        }
        Some(Goal::Credits { target }) => {
            println!(
                "{}",
                serde_json::json!({
                    "mode": "credits",
                    "target": target,
                    // Credits only land once the acceptance gate accepts, so a
                    // credits goal carries a wall-clock stop as well.
                    "ceiling_seconds": CREDITS_GOAL_CEILING_SECS,
                })
            );
            std::process::exit(0);
        }
        None => {
            eprintln!(
                "usage: slashwork-offload goal <90s|30m|2h|200cr>  (a positive number and a unit)"
            );
            std::process::exit(EXIT_USAGE);
        }
    }
}

/// `credits`: print the signed-in earner's credit balance. An earn loop working
/// to a credits goal reads this once for its baseline and again after each
/// submit, since credits settle asynchronously behind the acceptance gate.
fn cmd_credits() -> ! {
    let Some(token) = resolve_token() else {
        eprintln!("slashwork-offload credits: no slashwork token (run login)");
        std::process::exit(EXIT_AUTH);
    };
    let Some(base) = resolve_base() else {
        eprintln!("slashwork-offload credits: base url is not https");
        std::process::exit(EXIT_BASE);
    };
    let (code, body) = fetch_me(&base, &token);
    match code {
        200 => {
            if let Some(credits) = credits_balance(&body) {
                println!("{}", serde_json::json!({ "credits": credits }));
                std::process::exit(0);
            }
            eprintln!("slashwork-offload credits: /api/me had no credit balance");
            std::process::exit(EXIT_FAIL);
        }
        401 | 403 => {
            eprintln!("slashwork-offload credits: token rejected");
            std::process::exit(EXIT_AUTH);
        }
        other => {
            eprintln!("slashwork-offload credits: /api/me returned {other}");
            std::process::exit(EXIT_FAIL);
        }
    }
}

// --- login ---

/// Start the CLI auth request, print the verify URL, and poll for the issued
/// token until approval or the 10-minute request TTL.
fn cmd_login() -> ! {
    let Some(base) = resolve_base() else {
        eprintln!("slashwork-offload login: base url is not https");
        std::process::exit(EXIT_BASE);
    };
    let Some((request_id, verify_url)) = login_start(&base) else {
        eprintln!("slashwork-offload login: could not start the auth request");
        std::process::exit(EXIT_FAIL);
    };
    eprintln!("Open this URL in your browser to authorize slashwork:\n\n    {verify_url}\n");
    open_browser(&verify_url);
    eprintln!("Waiting for you to approve...");

    let deadline = Instant::now() + Duration::from_mins(10);
    loop {
        if Instant::now() >= deadline {
            eprintln!("slashwork-offload login: timed out waiting for approval");
            std::process::exit(EXIT_TIMEOUT);
        }
        sleep_bounded(Duration::from_secs(4), deadline);
        let (code, body) = login_poll_once(&base, &request_id);
        match login_poll(code, &body) {
            LoginPoll::Token(token) => match write_token(&token) {
                Ok(path) => {
                    eprintln!("Authorized. Token saved to {path}.");
                    std::process::exit(0);
                }
                Err(e) => {
                    eprintln!("slashwork-offload login: got a token but could not save it: {e}");
                    std::process::exit(EXIT_FAIL);
                }
            },
            LoginPoll::Pending | LoginPoll::Retry => {}
            LoginPoll::Gone => {
                eprintln!("slashwork-offload login: the request expired or was already used; run login again");
                std::process::exit(EXIT_FAIL);
            }
        }
    }
}

/// Write the token to `~/.slashwork/token` (0600 on unix). Returns the path.
///
/// On Windows there is no chmod; the file inherits the profile directory's ACL,
/// which is already user-only.
fn write_token(token: &str) -> std::io::Result<String> {
    let home = home_dir().ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::NotFound, "no HOME or USERPROFILE")
    })?;
    let dir = std::path::Path::new(&home).join(".slashwork");
    std::fs::create_dir_all(&dir)?;
    let path = dir.join("token");
    std::fs::write(&path, token)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(path.display().to_string())
}

/// Best-effort: open the verify URL in the user's browser. The URL is always
/// printed too, so a failure here is fine.
fn open_browser(url: &str) {
    let mut cmd = if cfg!(target_os = "macos") {
        let mut c = std::process::Command::new("open");
        c.arg(url);
        c
    } else if cfg!(target_os = "windows") {
        let mut c = std::process::Command::new("cmd");
        c.args(["/C", "start", "", url]);
        c
    } else {
        let mut c = std::process::Command::new("xdg-open");
        c.arg(url);
        c
    };
    let _ = cmd.spawn();
}

// --- claim (earner) ---

/// Hold the queue feed open and claim the next task we win, printing the job
/// JSON (with `task_id` and `base` injected) on success.
fn cmd_claim(rest: &[String]) -> ! {
    let deadline = parse_timeout(rest).map(|d| Instant::now() + d);
    let Some(token) = resolve_token() else {
        eprintln!("slashwork-offload claim: no slashwork token (run login)");
        std::process::exit(EXIT_AUTH);
    };
    let Some(base) = resolve_base() else {
        eprintln!("slashwork-offload claim: base url is not https");
        std::process::exit(EXIT_BASE);
    };

    let mut backoff = Duration::from_secs(2);
    let max_backoff = Duration::from_secs(30);
    loop {
        if past_deadline(deadline) {
            eprintln!("slashwork-offload claim: no task claimed before the timeout");
            std::process::exit(EXIT_TIMEOUT);
        }
        match probe_auth(&base, &token) {
            200 => {}
            401 | 403 => {
                eprintln!("slashwork-offload claim: token rejected");
                std::process::exit(EXIT_AUTH);
            }
            _ => {
                sleep_backoff(&mut backoff, max_backoff, deadline);
                continue;
            }
        }

        let chunk = chunk_secs(deadline, 300);
        let mut scanner = SseTaskScanner::new();
        let mut claimed: Option<String> = None;
        let mut auth_failed = false;
        stream_queue(&base, &token, chunk, |line| {
            let Some(id) = scanner.feed(line) else {
                return LineAction::Continue;
            };
            let (code, body) = post_claim(&base, &token, &id);
            match claim_outcome(code, body) {
                ClaimOutcome::Claimed { job } => {
                    claimed = Some(augment_job(&job, &id, &base));
                    LineAction::Stop
                }
                ClaimOutcome::AuthFailed => {
                    auth_failed = true;
                    LineAction::Stop
                }
                ClaimOutcome::Gated | ClaimOutcome::Lost => LineAction::Continue,
            }
        });

        if let Some(job) = claimed {
            println!("{job}");
            std::process::exit(0);
        }
        if auth_failed {
            eprintln!("slashwork-offload claim: token rejected");
            std::process::exit(EXIT_AUTH);
        }
        // The stream ended with no claim: back off, then reconnect.
        sleep_backoff(&mut backoff, max_backoff, deadline);
    }
}

/// Inject `task_id` (if absent) and `base` into a claimed job's JSON, so the
/// adapter that stages and later submits it knows both. Falls back to the raw
/// body if it is not a JSON object.
fn augment_job(job: &str, task_id: &str, base: &str) -> String {
    match serde_json::from_str::<Value>(job) {
        Ok(Value::Object(mut m)) => {
            m.entry("task_id".to_string())
                .or_insert_with(|| Value::String(task_id.to_string()));
            m.insert("base".to_string(), Value::String(base.to_string()));
            Value::Object(m).to_string()
        }
        _ => job.to_string(),
    }
}

// --- submit (earner) ---

/// Read an artifact from stdin and submit it for a claimed task.
fn cmd_submit(rest: &[String]) -> ! {
    let mut task_id: Option<&str> = None;
    let mut tokens: i64 = 0;
    let mut it = rest.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--tokens" => {
                tokens = it.next().and_then(|v| v.parse().ok()).unwrap_or(0);
            }
            other if !other.starts_with("--") && task_id.is_none() => task_id = Some(other),
            _ => {}
        }
    }
    let Some(task_id) = task_id.filter(|id| looks_like_task_id(id)) else {
        eprintln!("usage: slashwork-offload submit <task_id> [--tokens N]  (artifact on stdin)");
        std::process::exit(EXIT_USAGE);
    };

    let mut artifact = String::new();
    if std::io::stdin().read_to_string(&mut artifact).is_err() {
        eprintln!("slashwork-offload submit: could not read the artifact from stdin");
        std::process::exit(EXIT_FAIL);
    }
    if artifact.trim().is_empty() {
        eprintln!("slashwork-offload submit: empty artifact, nothing to submit");
        std::process::exit(EXIT_USAGE);
    }

    let Some(token) = resolve_token() else {
        eprintln!("slashwork-offload submit: no slashwork token (run login)");
        std::process::exit(EXIT_AUTH);
    };
    let Some(base) = resolve_base() else {
        eprintln!("slashwork-offload submit: base url is not https");
        std::process::exit(EXIT_BASE);
    };

    let (code, body) = submit_task(&base, &token, task_id, &artifact, tokens.max(0));
    match submit_outcome(code, &body) {
        SubmitOutcome::Accepted => {
            eprintln!("slashwork-offload submit: accepted; the acceptance gate is judging it");
            std::process::exit(0);
        }
        SubmitOutcome::Failed { code, detail } => {
            eprintln!("slashwork-offload submit: failed (HTTP {code}): {detail}");
            std::process::exit(EXIT_FAIL);
        }
    }
}

// --- small helpers ---

/// The coordinator's task id shape (36-char hyphenated hex).
fn looks_like_task_id(s: &str) -> bool {
    s.len() == 36 && s.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
}

/// Parse `--timeout <secs>` from the trailing args.
fn parse_timeout(rest: &[String]) -> Option<Duration> {
    let mut it = rest.iter();
    while let Some(a) = it.next() {
        if a == "--timeout" {
            return it
                .next()
                .and_then(|v| v.parse().ok())
                .map(Duration::from_secs);
        }
    }
    None
}

fn past_deadline(deadline: Option<Instant>) -> bool {
    deadline.is_some_and(|dl| Instant::now() >= dl)
}

/// Sleep `dur`, but never past `deadline`.
fn sleep_bounded(dur: Duration, deadline: Instant) {
    std::thread::sleep(dur.min(deadline.saturating_duration_since(Instant::now())));
}

/// Sleep the current backoff (bounded by any deadline), then double it toward
/// `max`.
fn sleep_backoff(backoff: &mut Duration, max: Duration, deadline: Option<Instant>) {
    let d = match deadline {
        Some(dl) => (*backoff).min(dl.saturating_duration_since(Instant::now())),
        None => *backoff,
    };
    std::thread::sleep(d);
    *backoff = (*backoff * 2).min(max);
}

/// Seconds to hold one SSE connection: `cap`, or the time left before the
/// deadline, whichever is smaller (at least 1).
fn chunk_secs(deadline: Option<Instant>, cap: u64) -> u64 {
    match deadline {
        Some(dl) => dl
            .saturating_duration_since(Instant::now())
            .as_secs()
            .clamp(1, cap),
        None => cap,
    }
}
