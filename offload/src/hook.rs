//! The offloader hook, ported off `jq`.
//!
//! `intercept.sh` used to parse the `PreToolUse` envelope, hold the one-time
//! consent marker, keep the savings log, render the receipt plot, and shape the
//! `deny` decision, all with `jq`. That made `jq` a hard dependency of routing:
//! Git Bash on Windows ships no `jq`, so the hook hit `command -v jq || exit 0`
//! and every spawn ran locally with no explanation.
//!
//! All of that lives here now. The shell hook is a shim that locates the core and
//! execs `slashwork-offload hook`, so the offloader needs nothing on the machine
//! beyond the binary the `SessionStart` hook installs, and a PowerShell shim for
//! Windows without Git Bash becomes a few lines rather than a port.
//!
//! Everything in this module is pure except the small filesystem helpers at the
//! bottom, which is what lets the tests cover the decision shaping directly.

use serde::Deserialize;
use std::fmt::Write as _;
use std::io::Write as _;

/// Bar width, in columns, of the longest row in the savings plot.
const PLOT_WIDTH: u128 = 24;
/// How many recent offloads the plot draws.
const PLOT_ROWS: usize = 8;
/// How many entries the savings log keeps. It is a display buffer, not history.
pub const SAVINGS_KEPT: usize = 20;

/// The `PreToolUse` envelope Claude Code sends on stdin. Every field is optional:
/// a shape we do not recognise must read as "not routable" and fall through to
/// the local spawn, never as an error.
#[derive(Deserialize, Default)]
pub struct Envelope {
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default)]
    pub tool_name: Option<String>,
    #[serde(default)]
    pub tool_input: ToolInput,
    /// The project directory Claude Code ran the hook for. Bundled reviews
    /// collect material relative to it; absent on older builds, where the
    /// process working directory (also the project) stands in.
    #[serde(default)]
    pub cwd: Option<String>,
}

#[derive(Deserialize, Default)]
pub struct ToolInput {
    #[serde(default)]
    pub prompt: String,
    /// The agent type the spawn addresses (Claude Code's `subagent_type`).
    /// Naming the offload agent selects the explicit routing path.
    #[serde(default)]
    pub subagent_type: Option<String>,
}

impl Envelope {
    /// Parse an envelope, treating malformed JSON as an empty one so the caller
    /// takes the same "run locally" path it would for an unrecognised tool.
    #[must_use]
    pub fn parse(raw: &str) -> Self {
        serde_json::from_str(raw).unwrap_or_default()
    }

    /// Whether this is a subagent spawn we should consider at all.
    ///
    /// The tool is `Task` on older Claude Code builds and `Agent` on newer ones,
    /// with the same `tool_input.prompt` shape. Accepting only one leaves
    /// interception silently inert on the other side of the rename.
    #[must_use]
    pub fn is_subagent_spawn(&self) -> bool {
        matches!(self.tool_name.as_deref(), Some("Task" | "Agent"))
    }

    /// The session identifier, reduced to characters that are safe in a
    /// filename. The consent marker is named after it, and the value arrives
    /// from outside this process.
    #[must_use]
    pub fn session_key(&self) -> String {
        let raw = self.session_id.as_deref().unwrap_or("default");
        let key: String = raw
            .chars()
            .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
            .take(64)
            .collect();
        if key.is_empty() {
            "default".to_string()
        } else {
            key
        }
    }
}

impl Envelope {
    /// Where bundling looks for the repo: the envelope's `cwd` when present,
    /// the process working directory otherwise.
    #[must_use]
    pub fn cwd_or_process(&self) -> std::path::PathBuf {
        match self.cwd.as_deref() {
            Some(c) if !c.is_empty() => std::path::PathBuf::from(c),
            _ => std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from(".")),
        }
    }
}

/// Whether a prompt is one of slashwork's own earner worker spawns.
///
/// Those carry `task_id:` (the submit path keys on the same marker). The
/// classifier exempts them too, but short-circuiting here skips a subprocess on
/// the spawns an earning session makes constantly, and means we can never repost
/// our own work.
#[must_use]
pub fn is_self_worker(prompt: &str) -> bool {
    prompt.contains("task_id:")
}

/// Render the ASCII savings plot shown in the receipt, oldest to newest, scaled
/// so the largest recent offload fills [`PLOT_WIDTH`] columns.
///
/// Values arrive from the coordinator as signed counts. A negative one is not
/// meaningful as a saving, so it reads as zero rather than skewing the scale.
#[must_use]
pub fn render_plot(values: &[i64]) -> String {
    let rows = &values[values.len().saturating_sub(PLOT_ROWS)..];
    // A zero max would divide by zero, and every bar is empty anyway.
    let max = u128::from(
        rows.iter()
            .map(|v| v.max(&0).unsigned_abs())
            .max()
            .unwrap_or(0),
    )
    .max(1);
    let mut out = String::from("tokens saved, recent offloads:");
    for (i, &v) in rows.iter().enumerate() {
        let v = v.max(0);
        // u128 so a large token count cannot overflow the scaling multiply.
        let mut width = u128::from(v.unsigned_abs()) * PLOT_WIDTH / max;
        // Any real saving gets at least one column, or a small offload next to a
        // large one renders as if it saved nothing.
        if width == 0 && v > 0 {
            width = 1;
        }
        let bars = "#".repeat(usize::try_from(width).unwrap_or(0));
        let mark = if i + 1 == rows.len() { "  <- now" } else { "" };
        let _ = write!(out, "\n  {v:>8}  {bars}{mark}");
    }
    out
}

/// The receipt printed when an offload comes back, above the returned artifact.
#[must_use]
pub fn receipt(tokens_used: i64, settled: i64, total: i64, plot: &str) -> String {
    format!(
        "/work offloaded this task: saved {tokens_used} tokens, settled {settled} cr.\n{plot}\n\
         total saved: {total} tokens across your offloads. run /earn to bank credits back."
    )
}

// --- filesystem helpers ---

/// `~/.slashwork`, creating it if needed.
fn state_dir() -> Option<std::path::PathBuf> {
    let home = crate::http::home_dir()?;
    let dir = std::path::Path::new(&home).join(".slashwork");
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir)
}

/// Append one offload's saving and return the recent window for the plot.
/// Best-effort: a failure here costs a plot, never the artifact.
#[must_use]
pub fn record_saving(tokens: i64) -> Vec<i64> {
    let Some(dir) = state_dir() else {
        return vec![tokens];
    };
    let path = dir.join("savings.log");
    let mut values: Vec<i64> = std::fs::read_to_string(&path)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.trim().parse().ok())
        .collect();
    values.push(tokens);
    let kept = values.split_off(values.len().saturating_sub(SAVINGS_KEPT));
    let body = kept.iter().fold(String::new(), |mut acc, v| {
        let _ = writeln!(acc, "{v}");
        acc
    });
    let _ = std::fs::write(&path, body);
    kept
}

/// How much of a spawn's prompt the route log keeps when capture is on.
/// Enough to recognise what the task was, bounded so the log stays small and
/// readable.
pub(crate) const PROMPT_CAPTURE_MAX: usize = 1000;

/// Shape one route-log record. Split out from the write so the truncation
/// rules are testable without touching the filesystem.
fn log_line(ts: u64, decision: &str, detail: &str, prompt: Option<&str>) -> serde_json::Value {
    let mut line = serde_json::json!({ "ts": ts, "decision": decision, "detail": detail });
    if let Some(p) = prompt {
        let kept: String = p.chars().take(PROMPT_CAPTURE_MAX).collect();
        line["prompt"] = serde_json::Value::from(kept);
        line["prompt_len"] = serde_json::Value::from(p.chars().count());
    }
    line
}

/// Whether this run records prompts alongside verdicts.
///
/// Off by default and deliberately opt-in: the reason a spawn declined is
/// harmless, but the prompt that declined can carry repo content, so it is the
/// user's call whether it lands on disk. Nothing here is ever sent anywhere;
/// the route log is local.
fn capture_prompts() -> bool {
    std::env::var("SLASHWORK_ROUTE_LOG_PROMPTS").is_ok_and(|v| v == "1" || v == "true")
}

/// Append a routed/local verdict to the route log, so the work on widening the
/// routable slice keeps signal that stderr alone would lose. Point
/// `SLASHWORK_ROUTE_LOG` at `/dev/null` to disable.
///
/// `prompt` is recorded only when `SLASHWORK_ROUTE_LOG_PROMPTS=1`. Without it
/// the log says why a spawn declined but not what declined, which leaves the
/// largest bucket unauditable: a spawn that truly reads the repo and one that
/// merely names a path in passing produce the same line.
pub fn route_log(decision: &str, detail: &str, prompt: Option<&str>) {
    let path = match std::env::var("SLASHWORK_ROUTE_LOG") {
        Ok(p) if p == "/dev/null" || p.is_empty() => return,
        Ok(p) => std::path::PathBuf::from(p),
        Err(_) => match state_dir() {
            Some(d) => d.join("route-log.jsonl"),
            None => return,
        },
    };
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    let line = log_line(
        ts,
        decision,
        detail,
        if capture_prompts() { prompt } else { None },
    );
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        let _ = writeln!(f, "{line}");
    }
}

/// Path of the consent marker: durable and per user, in the state dir.
///
/// It used to be per session, in the temp dir. The disclosure is a one-time
/// explanation of what routing does, but keyed per session it was charged again
/// in every new console, and it costs a routable spawn each time (that spawn
/// runs locally by design). Measured on a heavy user: 11 subagent spawns in 24
/// hours across 19 sessions, so nearly every session held exactly one routable
/// spawn and the gate consumed it. Per session, the gate was a permanent off
/// switch. Per user, it is what it says: shown once, then routing runs.
///
/// Falls back to the old per-session temp marker when there is no state dir (no
/// resolvable home). That degrades to the previous behaviour rather than
/// disclosing on every single spawn.
#[must_use]
pub fn consent_marker(session_key: &str) -> std::path::PathBuf {
    match state_dir() {
        Some(dir) => dir.join("consent"),
        None => std::env::temp_dir().join(format!("slashwork-intercept-consent-{session_key}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- Route-log prompt capture ---
    //
    // The log records why a spawn declined but never what it declined, so the
    // largest bucket ("local path reference", 77% of declines on a real
    // machine) cannot be audited: there is no way to tell a spawn that truly
    // reads the repo from one that merely names a path in passing. Capture is
    // opt-in and local-only; these tests cover the shaping, not the file.

    #[test]
    fn no_prompt_field_when_capture_is_off() {
        let line = log_line(1, "local", "local path reference", None);
        assert!(line.get("prompt").is_none(), "leaked a prompt: {line}");
        assert!(line.get("prompt_len").is_none());
    }

    #[test]
    fn a_captured_prompt_is_recorded_whole_when_short() {
        let line = log_line(
            1,
            "local",
            "local path reference",
            Some("read ./src/main.rs"),
        );
        assert_eq!(line["prompt"], "read ./src/main.rs");
        assert_eq!(line["prompt_len"], 18);
    }

    #[test]
    fn a_captured_prompt_is_truncated_but_reports_its_true_length() {
        let long = "x".repeat(PROMPT_CAPTURE_MAX + 500);
        let line = log_line(1, "local", "local path reference", Some(&long));
        let got = line["prompt"].as_str().expect("prompt is a string");
        assert_eq!(got.chars().count(), PROMPT_CAPTURE_MAX);
        assert_eq!(line["prompt_len"], PROMPT_CAPTURE_MAX + 500);
    }

    #[test]
    fn truncation_lands_on_a_character_boundary() {
        // A multibyte prompt truncated by bytes would panic or emit invalid
        // UTF-8; the cap counts characters.
        let long = "é".repeat(PROMPT_CAPTURE_MAX + 10);
        let line = log_line(1, "local", "detail", Some(&long));
        assert_eq!(
            line["prompt"].as_str().expect("string").chars().count(),
            PROMPT_CAPTURE_MAX
        );
    }

    #[test]
    fn parses_a_task_envelope() {
        let e = Envelope::parse(
            r#"{"session_id":"abc-123","tool_name":"Task","tool_input":{"prompt":"research X"}}"#,
        );
        assert!(e.is_subagent_spawn());
        assert_eq!(e.session_key(), "abc-123");
        assert_eq!(e.tool_input.prompt, "research X");
    }

    #[test]
    fn accepts_both_task_and_agent() {
        for tool in ["Task", "Agent"] {
            let raw = format!(r#"{{"tool_name":"{tool}","tool_input":{{"prompt":"p"}}}}"#);
            assert!(Envelope::parse(&raw).is_subagent_spawn(), "{tool}");
        }
    }

    #[test]
    fn rejects_other_tools_and_junk() {
        assert!(!Envelope::parse(r#"{"tool_name":"Bash"}"#).is_subagent_spawn());
        assert!(!Envelope::parse("not json at all").is_subagent_spawn());
        assert!(!Envelope::parse("").is_subagent_spawn());
    }

    #[test]
    fn missing_prompt_reads_as_empty() {
        let e = Envelope::parse(r#"{"tool_name":"Task","tool_input":{}}"#);
        assert!(e.tool_input.prompt.is_empty());
    }

    #[test]
    fn session_key_strips_path_traversal() {
        let e = Envelope::parse(r#"{"session_id":"../../etc/passwd","tool_name":"Task"}"#);
        let key = e.session_key();
        assert!(!key.contains('/'), "{key}");
        assert!(!key.contains('.'), "{key}");
    }

    #[test]
    fn session_key_defaults_when_absent_or_unusable() {
        assert_eq!(Envelope::parse("{}").session_key(), "default");
        assert_eq!(
            Envelope::parse(r#"{"session_id":"///"}"#).session_key(),
            "default"
        );
    }

    #[test]
    fn detects_our_own_worker_spawns() {
        assert!(is_self_worker("run this task_id: abc"));
        assert!(!is_self_worker("summarize the release notes"));
    }

    #[test]
    fn plot_scales_the_largest_bar_to_full_width() {
        let plot = render_plot(&[100]);
        assert!(plot.contains(&"#".repeat(24)), "{plot}");
        assert!(plot.ends_with("  <- now"), "{plot}");
    }

    #[test]
    fn plot_gives_a_small_nonzero_saving_one_column() {
        let plot = render_plot(&[1000, 1]);
        let last = plot.lines().last().unwrap();
        assert!(last.contains('#'), "{last}");
        assert_eq!(last.matches('#').count(), 1, "{last}");
    }

    #[test]
    fn plot_handles_all_zeroes_without_dividing_by_zero() {
        let plot = render_plot(&[0, 0]);
        assert!(plot.contains("tokens saved"), "{plot}");
    }

    #[test]
    fn plot_shows_only_the_recent_window() {
        let many: Vec<i64> = (1..=20).collect();
        let plot = render_plot(&many);
        assert_eq!(plot.lines().count(), PLOT_ROWS + 1, "{plot}");
    }

    #[test]
    fn plot_of_an_empty_log_is_just_the_header() {
        assert_eq!(render_plot(&[]), "tokens saved, recent offloads:");
    }

    #[test]
    fn plot_does_not_overflow_on_huge_savings() {
        let plot = render_plot(&[i64::MAX, i64::MAX]);
        assert!(plot.contains('#'), "{plot}");
    }

    #[test]
    fn plot_treats_a_negative_saving_as_zero() {
        let plot = render_plot(&[100, -5]);
        let last = plot.lines().last().unwrap();
        assert!(!last.contains('#'), "{last}");
        assert!(last.contains('0'), "{last}");
    }
}
