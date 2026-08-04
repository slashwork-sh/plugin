//! The earner side: the pure parsing behind `claim`, `submit`, and `login`.
//! Ported from the Claude Code `earn-listen.sh` / `submit.sh` hooks and the
//! coordinator's `cli_auth` flow. The ureq I/O that feeds these lives in
//! `crate::http`; the orchestration loops are in `main`.

use crate::http::is_uuid;
use serde_json::Value;

/// Scans the lines of the `GET /api/queue/stream` SSE feed for task ids. The
/// queue emits `event: task` then a `data: {"id": "..."}` line; an id counts
/// only when it follows a task event (mirrors the reader in `earn-listen.sh`).
#[derive(Default)]
pub struct SseTaskScanner {
    expect: bool,
}

impl SseTaskScanner {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Feed one SSE line (trailing CR already stripped). Returns the task id when
    /// a valid `data:` id lands right after a task event.
    pub fn feed(&mut self, line: &str) -> Option<String> {
        if line == "event: task" || line == "event:task" {
            self.expect = true;
            None
        } else if line.starts_with("event:") {
            self.expect = false;
            None
        } else if let Some(rest) = line.strip_prefix("data:") {
            if !self.expect {
                return None;
            }
            self.expect = false;
            let id = serde_json::from_str::<Value>(rest.trim_start())
                .ok()
                .and_then(|v| v.get("id").and_then(Value::as_str).map(str::to_string))?;
            is_uuid(&id).then_some(id)
        } else {
            None
        }
    }
}

/// The result of `POST /api/tasks/{id}/claim`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClaimOutcome {
    /// Won the task; `job` is the response body (the staged job JSON).
    Claimed { job: String },
    /// 401: the token is dead. Stop.
    AuthFailed,
    /// 403: the per-class score gate refused this task to an unproven earner.
    /// Not a dead token, so keep listening for the next one.
    Gated,
    /// 409 (lost the race), 5xx, or anything else transient: keep listening.
    Lost,
}

/// Map a claim response to an outcome. Mirrors `earn-listen.sh`: 200 claimed,
/// 401 dead token, 403 score-gated (skip), everything else a lost race.
#[must_use]
pub fn claim_outcome(code: u16, body: String) -> ClaimOutcome {
    match code {
        200 => ClaimOutcome::Claimed { job: body },
        401 => ClaimOutcome::AuthFailed,
        403 => ClaimOutcome::Gated,
        _ => ClaimOutcome::Lost,
    }
}

/// The result of `POST /api/tasks/{id}/submit`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SubmitOutcome {
    /// 201: the artifact was accepted for review; the acceptance gate now judges
    /// it async (not yet returned to the requester).
    Accepted,
    /// Any non-201: the work is done but nothing reached the requester.
    Failed { code: u16, detail: String },
}

/// Map a submit response to an outcome. 201 is accepted-for-review; everything
/// else is a failure carrying a short detail for the log.
#[must_use]
pub fn submit_outcome(code: u16, body: &str) -> SubmitOutcome {
    if code == 201 {
        SubmitOutcome::Accepted
    } else {
        // Keep the detail short and control-char free for a one-line log.
        let detail: String = body.chars().filter(|c| !c.is_control()).take(300).collect();
        SubmitOutcome::Failed { code, detail }
    }
}

/// An earner run goal: a time budget (`90s`, `30m`, `2h`) or the credits earned
/// this run (`200cr`). Mirrors the goal syntax `/earn` takes, and lives here so
/// every adapter's earn loop reads the same spec the same way.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Goal {
    /// Run until this many seconds have elapsed.
    Time { seconds: u64 },
    /// Run until the credit balance has risen by `target` since the run began.
    /// Credits only land when the acceptance gate accepts, so a credits goal
    /// also carries `CREDITS_GOAL_CEILING_SECS` as a wall-clock stop.
    Credits { target: i64 },
}

/// The wall-clock ceiling on a credits goal, so a cold pool or a run of
/// rejections cannot hold the loop open forever. Matches `/earn`'s 24h ceiling.
pub const CREDITS_GOAL_CEILING_SECS: u64 = 86_400;

/// Parse an earn goal (`90s`, `30m`, `2h`, `200cr`). Returns `None` for anything
/// without a positive number and a known unit, which the caller reports as a
/// usage error rather than guessing at an unbounded run.
#[must_use]
pub fn parse_goal(spec: &str) -> Option<Goal> {
    let spec = spec.trim().to_ascii_lowercase();
    let split = spec.find(|c: char| !c.is_ascii_digit())?;
    let (digits, unit) = spec.split_at(split);
    let n: u64 = digits.parse().ok().filter(|n| *n > 0)?;
    match unit.trim() {
        "s" | "sec" | "secs" | "second" | "seconds" => Some(Goal::Time { seconds: n }),
        "m" | "min" | "mins" | "minute" | "minutes" => Some(Goal::Time { seconds: n * 60 }),
        "h" | "hr" | "hrs" | "hour" | "hours" => Some(Goal::Time { seconds: n * 3600 }),
        "cr" | "credit" | "credits" => Some(Goal::Credits {
            target: i64::try_from(n).ok()?,
        }),
        _ => None,
    }
}

/// Read the credit balance out of a `GET /api/me` body. `None` when the body is
/// not the shape we expect, which a caller treats as "cannot measure progress"
/// rather than as zero credits.
#[must_use]
pub fn credits_balance(body: &str) -> Option<i64> {
    serde_json::from_str::<Value>(body)
        .ok()?
        .get("credits")?
        .as_i64()
}

/// The result of one poll of `GET /auth/cli/{id}/token`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LoginPoll {
    /// 200 with a token: authorized. Write it and stop.
    Token(String),
    /// 202: the user has not approved yet. Keep polling.
    Pending,
    /// 410: the request expired or was already claimed. Stop.
    Gone,
    /// Any transient status: keep polling.
    Retry,
}

/// Map a token-poll response to an outcome. Mirrors `cli_auth::get_token`: 200
/// carries the token, 202 is pending, 410 is gone.
#[must_use]
pub fn login_poll(code: u16, body: &str) -> LoginPoll {
    match code {
        200 => serde_json::from_str::<Value>(body)
            .ok()
            .and_then(|v| v.get("token").and_then(Value::as_str).map(str::to_string))
            .map_or(LoginPoll::Retry, LoginPoll::Token),
        202 => LoginPoll::Pending,
        410 => LoginPoll::Gone,
        _ => LoginPoll::Retry,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        claim_outcome, credits_balance, login_poll, parse_goal, submit_outcome, ClaimOutcome, Goal,
        LoginPoll, SseTaskScanner, SubmitOutcome,
    };

    #[test]
    fn scanner_extracts_a_task_id_after_a_task_event() {
        let mut s = SseTaskScanner::new();
        assert_eq!(s.feed("event: task"), None);
        assert_eq!(
            s.feed(r#"data: {"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}"#)
                .as_deref(),
            Some("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        );
    }

    #[test]
    fn scanner_accepts_the_no_space_event_form() {
        let mut s = SseTaskScanner::new();
        assert_eq!(s.feed("event:task"), None);
        assert!(s
            .feed(r#"data:{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}"#)
            .is_some());
    }

    #[test]
    fn scanner_ignores_data_without_a_task_event() {
        let mut s = SseTaskScanner::new();
        // A data line with no preceding task event is not a claimable task.
        assert_eq!(
            s.feed(r#"data: {"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}"#),
            None
        );
    }

    #[test]
    fn scanner_resets_on_a_non_task_event() {
        let mut s = SseTaskScanner::new();
        assert_eq!(s.feed("event: task"), None);
        assert_eq!(s.feed("event: heartbeat"), None); // resets expectation
        assert_eq!(
            s.feed(r#"data: {"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}"#),
            None
        );
    }

    #[test]
    fn scanner_rejects_a_non_uuid_id() {
        let mut s = SseTaskScanner::new();
        assert_eq!(s.feed("event: task"), None);
        assert_eq!(s.feed(r#"data: {"id":"not-a-uuid"}"#), None);
    }

    #[test]
    fn claim_statuses_map() {
        assert!(matches!(
            claim_outcome(200, "{\"task_id\":\"x\"}".to_string()),
            ClaimOutcome::Claimed { .. }
        ));
        assert_eq!(claim_outcome(401, String::new()), ClaimOutcome::AuthFailed);
        assert_eq!(claim_outcome(403, String::new()), ClaimOutcome::Gated);
        assert_eq!(claim_outcome(409, String::new()), ClaimOutcome::Lost);
        assert_eq!(claim_outcome(503, String::new()), ClaimOutcome::Lost);
    }

    #[test]
    fn submit_statuses_map() {
        assert_eq!(submit_outcome(201, "ok"), SubmitOutcome::Accepted);
        match submit_outcome(409, "already submitted\n\t") {
            SubmitOutcome::Failed { code, detail } => {
                assert_eq!(code, 409);
                assert_eq!(detail, "already submitted"); // control chars stripped
            }
            other @ SubmitOutcome::Accepted => panic!("expected failed, got {other:?}"),
        }
    }

    #[test]
    fn login_polls_map() {
        assert_eq!(
            login_poll(200, r#"{"token":"sw_abc"}"#),
            LoginPoll::Token("sw_abc".to_string())
        );
        assert_eq!(
            login_poll(202, r#"{"status":"pending"}"#),
            LoginPoll::Pending
        );
        assert_eq!(login_poll(410, r#"{"status":"gone"}"#), LoginPoll::Gone);
        assert_eq!(login_poll(500, "oops"), LoginPoll::Retry);
        // A 200 without a token field is not usable; keep polling.
        assert_eq!(login_poll(200, r#"{"status":"ok"}"#), LoginPoll::Retry);
    }

    #[test]
    fn goals_parse_every_time_unit() {
        assert_eq!(parse_goal("90s"), Some(Goal::Time { seconds: 90 }));
        assert_eq!(parse_goal("30m"), Some(Goal::Time { seconds: 1800 }));
        assert_eq!(parse_goal("2h"), Some(Goal::Time { seconds: 7200 }));
        assert_eq!(parse_goal("45 minutes"), Some(Goal::Time { seconds: 2700 }));
        assert_eq!(parse_goal(" 2 HOURS "), Some(Goal::Time { seconds: 7200 }));
    }

    #[test]
    fn goals_parse_credits() {
        assert_eq!(parse_goal("200cr"), Some(Goal::Credits { target: 200 }));
        assert_eq!(parse_goal("50 credits"), Some(Goal::Credits { target: 50 }));
    }

    #[test]
    fn bad_goals_are_rejected_rather_than_guessed() {
        // No unit, no number, unknown unit, and zero all have to be usage
        // errors: guessing here would start an unbounded run.
        assert_eq!(parse_goal("30"), None);
        assert_eq!(parse_goal("forever"), None);
        assert_eq!(parse_goal("10 bananas"), None);
        assert_eq!(parse_goal("0m"), None);
        assert_eq!(parse_goal(""), None);
    }

    #[test]
    fn credits_balance_reads_the_me_body() {
        assert_eq!(credits_balance(r#"{"credits":1234}"#), Some(1234));
        assert_eq!(credits_balance(r#"{"handle":"x"}"#), None);
        assert_eq!(credits_balance("not json"), None);
    }
}
