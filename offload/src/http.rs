//! The real coordinator client: `ureq` over the JSON API, implementing
//! [`crate::dispatch::Coordinator`]. Also resolves the bearer token and base URL
//! the way the design specifies (matching the existing Claude Code CLI), and the
//! pure response parsers, which are unit-tested here.

use crate::classify::Class;
use crate::dispatch::{Artifact, Coordinator, PollOutcome, PostOutcome};
use serde_json::Value;
use std::io::{BufRead, BufReader};
use std::time::{Duration, Instant};

/// The user's home directory: `HOME`, else `USERPROFILE`.
///
/// Native Windows sets `USERPROFILE` and not `HOME`, so a `HOME`-only lookup
/// makes the core inert whenever it is started by anything other than Git Bash
/// (which sets both). Every path the core reads or writes under `~/.slashwork`
/// resolves through here, so the token lands in and is read from one place
/// whichever shell launched the process.
#[must_use]
pub fn home_dir() -> Option<std::ffi::OsString> {
    std::env::var_os("HOME")
        .filter(|h| !h.is_empty())
        .or_else(|| std::env::var_os("USERPROFILE").filter(|h| !h.is_empty()))
}

/// Resolve the bearer token: `SLASHWORK_TOKEN`, else `~/.slashwork/token`.
#[must_use]
pub fn resolve_token() -> Option<String> {
    if let Ok(t) = std::env::var("SLASHWORK_TOKEN") {
        let t = t.trim();
        if !t.is_empty() {
            return Some(t.to_string());
        }
    }
    let home = home_dir()?;
    let path = std::path::Path::new(&home).join(".slashwork").join("token");
    let t = std::fs::read_to_string(path).ok()?;
    let t = t.trim();
    if t.is_empty() {
        None
    } else {
        Some(t.to_string())
    }
}

/// Resolve the base URL: `SLASHWORK_BASE_URL`, else `https://slashwork.sh`.
/// Returns `None` when it is neither https nor a localhost http dev URL, so the
/// bearer token never leaves for an arbitrary host.
#[must_use]
pub fn resolve_base() -> Option<String> {
    let raw = std::env::var("SLASHWORK_BASE_URL").unwrap_or_default();
    let raw = raw.trim();
    let base = if raw.is_empty() {
        "https://slashwork.sh"
    } else {
        raw
    };
    let base = base.trim_end_matches('/').to_string();
    if is_allowed_base(&base) {
        Some(base)
    } else {
        None
    }
}

/// Whether a base URL is safe to send the token to: https anywhere, or http only
/// for localhost / 127.0.0.1 (the dev exception). Mirrors `intercept.sh`.
#[must_use]
pub fn is_allowed_base(base: &str) -> bool {
    base.starts_with("https://")
        || base == "http://localhost"
        || base.starts_with("http://localhost:")
        || base == "http://127.0.0.1"
        || base.starts_with("http://127.0.0.1:")
}

/// A ureq-backed coordinator. Cheap to build; each call spins a short-lived
/// agent with the right read timeout so a hung server errors instead of hanging.
pub struct UreqCoordinator {
    base: String,
    token: String,
    /// Which harness is offloading (`hermes`, `openclaw`, `claude-code`), tagged
    /// on every posted task so the coordinator can attribute it. `None` posts no
    /// harness (read back as `claude-code`).
    harness: Option<String>,
}

impl UreqCoordinator {
    #[must_use]
    pub fn new(base: String, token: String, harness: Option<String>) -> Self {
        Self {
            base,
            token,
            harness,
        }
    }

    fn auth(&self) -> String {
        format!("Bearer {}", self.token)
    }
}

/// The JSON body for `POST /api/tasks`: the prompt, the context bundle (empty
/// for everything but bundled reviews), and the routing harness tag so the
/// coordinator can attribute the task.
fn create_task_body(
    class: Class,
    prompt: &str,
    bundle: &str,
    deadline_secs: u64,
    harness: Option<&str>,
) -> String {
    serde_json::json!({
        "class": class.as_str(),
        "prompt": prompt,
        "context_bundle": bundle,
        "deadline_secs": deadline_secs,
        "harness": harness,
    })
    .to_string()
}

/// Build a short-lived agent with the given per-read timeout (connect capped at
/// 10s). A hung server errors instead of hanging.
fn build_agent(read_timeout: Duration) -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(10))
        .timeout_read(read_timeout)
        .build()
}

/// `Bearer <token>` for the authorization header.
fn bearer(token: &str) -> String {
    format!("Bearer {token}")
}

/// Run a prepared request and return `(status, body)`. A non-2xx status is a
/// normal outcome here, not an error; a transport failure maps to `(0, "")`.
fn run(req: ureq::Request, body: Option<&str>) -> (u16, String) {
    let result = match body {
        Some(b) => req.send_string(b),
        None => req.call(),
    };
    match result {
        Ok(resp) => (resp.status(), resp.into_string().unwrap_or_default()),
        Err(ureq::Error::Status(code, resp)) => (code, resp.into_string().unwrap_or_default()),
        Err(_) => (0, String::new()),
    }
}

impl Coordinator for UreqCoordinator {
    fn post_task(
        &self,
        class: Class,
        prompt: &str,
        bundle: &str,
        deadline_secs: u64,
    ) -> PostOutcome {
        let url = format!("{}/api/tasks", self.base);
        let body = create_task_body(
            class,
            prompt,
            bundle,
            deadline_secs,
            self.harness.as_deref(),
        );
        let agent = build_agent(Duration::from_secs(15));
        match agent
            .post(&url)
            .set("authorization", &self.auth())
            .set("content-type", "application/json")
            .send_string(&body)
        {
            Ok(resp) => parse_post_created(&resp.into_string().unwrap_or_default()),
            Err(ureq::Error::Status(400, resp)) => {
                parse_post_400(&resp.into_string().unwrap_or_default())
            }
            Err(ureq::Error::Status(code, _)) => PostOutcome::Rejected {
                reason: format!("coordinator did not accept the task (HTTP {code})"),
            },
            Err(_) => PostOutcome::Rejected {
                reason: "coordinator unreachable".to_string(),
            },
        }
    }

    fn poll_result(&self, task_id: &str, wait_secs: u64) -> PollOutcome {
        let url = format!(
            "{}/api/tasks/{task_id}/result?wait_secs={wait_secs}",
            self.base
        );
        let agent = build_agent(Duration::from_secs(wait_secs + 5));
        match agent.get(&url).set("authorization", &self.auth()).call() {
            Ok(resp) => parse_poll(&resp.into_string().unwrap_or_default()),
            Err(_) => PollOutcome::Error,
        }
    }

    fn cancel(&self, task_id: &str) {
        let url = format!("{}/api/tasks/{task_id}", self.base);
        let agent = build_agent(Duration::from_secs(8));
        let _ = agent.delete(&url).set("authorization", &self.auth()).call();
    }
}

/// Parse a create response into `Created` when it carries a UUID task id.
fn parse_post_created(text: &str) -> PostOutcome {
    match serde_json::from_str::<Value>(text)
        .ok()
        .and_then(|v| v.get("task_id").and_then(Value::as_str).map(str::to_string))
    {
        Some(id) if is_uuid(&id) => PostOutcome::Created { task_id: id },
        _ => PostOutcome::Rejected {
            reason: "no task id from coordinator".to_string(),
        },
    }
}

/// Parse a 400 into `NotEnoughCredits` (the one rejection the user can act on)
/// or a generic rejection.
fn parse_post_400(text: &str) -> PostOutcome {
    let msg = serde_json::from_str::<Value>(text)
        .ok()
        .and_then(|v| {
            v.get("error")
                .and_then(|e| e.get("message"))
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .unwrap_or_default();
    if msg.contains("not enough credits") {
        PostOutcome::NotEnoughCredits { message: msg }
    } else {
        PostOutcome::Rejected {
            reason: format!("coordinator rejected the task (HTTP 400): {msg}"),
        }
    }
}

/// Map a result body's `status` to a poll outcome. A missing status or an
/// explicit `"error"` retries (like a transport blip); any other unexpected
/// status is treated as terminal (nothing to wait for).
fn parse_poll(text: &str) -> PollOutcome {
    let Ok(v) = serde_json::from_str::<Value>(text) else {
        return PollOutcome::Error;
    };
    match v.get("status").and_then(Value::as_str) {
        Some("returned") => PollOutcome::Returned(Artifact {
            artifact: v
                .get("artifact")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            tokens_used: v.get("tokens_used").and_then(Value::as_i64).unwrap_or(0),
            settled: v.get("settled").and_then(Value::as_i64).unwrap_or(0),
            tokens_saved_total: v
                .get("tokens_saved_total")
                .and_then(Value::as_i64)
                .unwrap_or(0),
        }),
        Some("claimed") => PollOutcome::Claimed,
        Some("reviewing") => PollOutcome::Reviewing,
        Some("error") | None => PollOutcome::Error,
        Some(_) => PollOutcome::Idle,
    }
}

/// A 36-char hyphenated hex string, the coordinator's task id shape.
pub(crate) fn is_uuid(s: &str) -> bool {
    s.len() == 36 && s.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
}

// --- Earner side: claim, submit, login. ---

/// `GET /api/me`: a cheap auth + reachability probe. Returns the HTTP status,
/// or 0 when the coordinator is unreachable.
#[must_use]
pub fn probe_auth(base: &str, token: &str) -> u16 {
    let agent = build_agent(Duration::from_secs(10));
    run(
        agent
            .get(&format!("{base}/api/me"))
            .set("authorization", &bearer(token)),
        None,
    )
    .0
}

/// `GET /api/me` with the body kept. Returns `(status, body)`; an earn loop
/// working to a credits goal reads the balance out of it to measure progress.
#[must_use]
pub fn fetch_me(base: &str, token: &str) -> (u16, String) {
    let agent = build_agent(Duration::from_secs(10));
    run(
        agent
            .get(&format!("{base}/api/me"))
            .set("authorization", &bearer(token)),
        None,
    )
}

/// `POST /api/tasks/{task_id}/claim`. Returns `(status, body)`; the body on 200
/// is the staged job JSON.
#[must_use]
pub fn post_claim(base: &str, token: &str, task_id: &str) -> (u16, String) {
    let agent = build_agent(Duration::from_secs(20));
    run(
        agent
            .post(&format!("{base}/api/tasks/{task_id}/claim"))
            .set("authorization", &bearer(token)),
        None,
    )
}

/// `POST /api/tasks/{task_id}/submit` with `{artifact, tokens_used}`. Returns
/// `(status, body)`; 201 means accepted for review.
#[must_use]
pub fn submit_task(
    base: &str,
    token: &str,
    task_id: &str,
    artifact: &str,
    tokens_used: i64,
) -> (u16, String) {
    let body = serde_json::json!({ "artifact": artifact, "tokens_used": tokens_used }).to_string();
    let agent = build_agent(Duration::from_secs(30));
    run(
        agent
            .post(&format!("{base}/api/tasks/{task_id}/submit"))
            .set("authorization", &bearer(token))
            .set("content-type", "application/json"),
        Some(&body),
    )
}

/// `POST /auth/cli/start` (no auth). Returns `(request_id, verify_url)` on
/// success. The user opens the verify URL and approves in the browser.
#[must_use]
pub fn login_start(base: &str) -> Option<(String, String)> {
    let agent = build_agent(Duration::from_secs(15));
    let (code, body) = run(agent.post(&format!("{base}/auth/cli/start")), None);
    if code != 200 {
        return None;
    }
    let v: Value = serde_json::from_str(&body).ok()?;
    let request_id = v.get("request_id").and_then(Value::as_str)?.to_string();
    let verify_url = v.get("verify_url").and_then(Value::as_str)?.to_string();
    Some((request_id, verify_url))
}

/// One poll of `GET /auth/cli/{request_id}/token`. Returns `(status, body)` for
/// `earn::login_poll`.
#[must_use]
pub fn login_poll_once(base: &str, request_id: &str) -> (u16, String) {
    let agent = build_agent(Duration::from_secs(10));
    run(
        agent.get(&format!("{base}/auth/cli/{request_id}/token")),
        None,
    )
}

/// What to do after handling one SSE line.
pub enum LineAction {
    Continue,
    Stop,
}

/// Open the queue SSE feed and call `on_line` for each line (trailing CR
/// stripped) until it returns `Stop`, the stream ends, or `max_secs` elapses. A
/// connect error returns immediately so the caller can reconnect.
pub fn stream_queue(
    base: &str,
    token: &str,
    max_secs: u64,
    mut on_line: impl FnMut(&str) -> LineAction,
) {
    // Per-read timeout above the coordinator's 15s heartbeat, so a healthy
    // stream is never cut mid-wait; the total is bounded by `max_secs` below.
    let agent = build_agent(Duration::from_secs(20));
    let Ok(resp) = agent
        .get(&format!("{base}/api/queue/stream"))
        .set("authorization", &bearer(token))
        .call()
    else {
        return;
    };
    let start = Instant::now();
    let reader = BufReader::new(resp.into_reader());
    for line in reader.lines() {
        if start.elapsed().as_secs() >= max_secs {
            break;
        }
        let Ok(line) = line else { break };
        let line = line.strip_suffix('\r').unwrap_or(line.as_str());
        if matches!(on_line(line), LineAction::Stop) {
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        create_task_body, is_allowed_base, is_uuid, parse_poll, parse_post_400, parse_post_created,
    };
    use crate::classify::Class;
    use crate::dispatch::{PollOutcome, PostOutcome};

    #[test]
    fn create_task_body_carries_the_bundle() {
        let v: serde_json::Value = serde_json::from_str(&create_task_body(
            Class::Review,
            "review this",
            "=== diff ===",
            60,
            None,
        ))
        .unwrap();
        assert_eq!(v["context_bundle"], "=== diff ===");
    }

    #[test]
    fn create_task_body_tags_the_harness() {
        let v: serde_json::Value = serde_json::from_str(&create_task_body(
            Class::Research,
            "do the thing",
            "",
            150,
            Some("hermes"),
        ))
        .unwrap();
        assert_eq!(v["class"], "research");
        assert_eq!(v["prompt"], "do the thing");
        assert_eq!(v["context_bundle"], "");
        assert_eq!(v["deadline_secs"], 150);
        assert_eq!(v["harness"], "hermes");
        // No harness posts null (the coordinator reads it back as claude-code).
        let v2: serde_json::Value =
            serde_json::from_str(&create_task_body(Class::Prose, "p", "", 90, None)).unwrap();
        assert!(v2["harness"].is_null());
    }

    #[test]
    fn allowed_bases() {
        assert!(is_allowed_base("https://slashwork.sh"));
        assert!(is_allowed_base("https://anything.example"));
        assert!(is_allowed_base("http://localhost"));
        assert!(is_allowed_base("http://localhost:8747"));
        assert!(is_allowed_base("http://127.0.0.1:5000"));
        // Cleartext to a real host, and localhost look-alikes, are refused.
        assert!(!is_allowed_base("http://evil.example"));
        assert!(!is_allowed_base("http://localhost.evil.example"));
        assert!(!is_allowed_base("ftp://slashwork.sh"));
    }

    #[test]
    fn uuid_shape() {
        assert!(is_uuid("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"));
        assert!(!is_uuid("not-a-uuid"));
        assert!(!is_uuid("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee-extra"));
    }

    #[test]
    fn create_response_parses_the_task_id() {
        match parse_post_created(
            r#"{"task_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","status":"queued","cost":50}"#,
        ) {
            PostOutcome::Created { task_id } => {
                assert_eq!(task_id, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");
            }
            other => panic!("expected created, got {other:?}"),
        }
    }

    #[test]
    fn create_without_a_task_id_is_rejected() {
        assert!(matches!(
            parse_post_created(r#"{"status":"queued"}"#),
            PostOutcome::Rejected { .. }
        ));
        assert!(matches!(
            parse_post_created("not json"),
            PostOutcome::Rejected { .. }
        ));
    }

    #[test]
    fn four_hundred_not_enough_credits() {
        match parse_post_400(
            r#"{"error":{"code":"validation_failed","message":"not enough credits to route this task: you have 3, it costs 50"}}"#,
        ) {
            PostOutcome::NotEnoughCredits { message } => {
                assert!(message.contains("you have 3, it costs 50"));
            }
            other => panic!("expected not-enough-credits, got {other:?}"),
        }
    }

    #[test]
    fn other_four_hundred_is_a_plain_rejection() {
        assert!(matches!(
            parse_post_400(r#"{"error":{"message":"class is required"}}"#),
            PostOutcome::Rejected { .. }
        ));
    }

    #[test]
    fn poll_statuses_map() {
        match parse_poll(
            r#"{"status":"returned","artifact":"the answer","tokens_used":123,"settled":12,"tokens_saved_total":4560}"#,
        ) {
            PollOutcome::Returned(a) => {
                assert_eq!(a.artifact, "the answer");
                assert_eq!(a.tokens_used, 123);
                assert_eq!(a.settled, 12);
                assert_eq!(a.tokens_saved_total, 4560);
            }
            other => panic!("expected returned, got {other:?}"),
        }
        assert_eq!(parse_poll(r#"{"status":"claimed"}"#), PollOutcome::Claimed);
        assert_eq!(
            parse_poll(r#"{"status":"reviewing"}"#),
            PollOutcome::Reviewing
        );
        assert_eq!(parse_poll(r#"{"status":"queued"}"#), PollOutcome::Idle);
        assert_eq!(parse_poll(r#"{"status":"expired"}"#), PollOutcome::Idle);
        // A missing status or an explicit error retries like a transport blip.
        assert_eq!(parse_poll(r#"{"status":"error"}"#), PollOutcome::Error);
        assert_eq!(parse_poll(r"{}"), PollOutcome::Error);
        assert_eq!(parse_poll("not json"), PollOutcome::Error);
    }

    // A multi-line artifact survives parsing whole (never truncated to line 1).
    #[test]
    fn multiline_artifact_survives() {
        let body = r#"{"status":"returned","artifact":"LINE ONE\nLINE TWO\nLINE THREE","tokens_used":200}"#;
        match parse_poll(body) {
            PollOutcome::Returned(a) => {
                assert!(a.artifact.contains("LINE ONE"));
                assert!(a.artifact.contains("LINE THREE"));
            }
            other => panic!("expected returned, got {other:?}"),
        }
    }
}
