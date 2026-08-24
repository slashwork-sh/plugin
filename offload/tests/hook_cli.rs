//! End-to-end check of the `hook` subcommand: pipe a real Claude Code
//! `PreToolUse` envelope to the binary and assert what it emits.
//!
//! These are the cases the shell hook used to cover with `jq` and a fake core,
//! narrowed to the ones that reach a verdict without a coordinator: a spawn we
//! never touch, and a spawn we would touch but cannot because there is no token.
//! The dispatch paths beyond that (artifact returned, cold pool, out of credits)
//! need a live coordinator and are covered by the coordinator repo's
//! `tests/e2e_offload_test.sh`; the shaping of what they print is unit-tested in
//! `hook.rs`.
//!
//! Every case asserts exit 0 with empty stdout, which is the contract that makes
//! Claude Code spawn the subagent locally exactly as it would without slashwork.

use std::io::Write;
use std::process::{Command, Stdio};

/// Run `slashwork-offload hook` with `envelope` on stdin in an isolated HOME, so
/// a developer's real `~/.slashwork/token` can never make these tests reach the
/// network. Returns stdout. Asserts exit 0: the hook must never fail.
fn hook(envelope: &str, token: Option<&str>) -> String {
    let sandbox = std::env::temp_dir().join(format!(
        "slashwork-hook-test-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    std::fs::create_dir_all(&sandbox).expect("sandbox");

    let mut cmd = Command::new(env!("CARGO_BIN_EXE_slashwork-offload"));
    cmd.arg("hook")
        .env("HOME", &sandbox)
        .env("USERPROFILE", &sandbox)
        // Never write a route log during tests.
        .env("SLASHWORK_ROUTE_LOG", "/dev/null")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    match token {
        Some(t) => cmd.env("SLASHWORK_TOKEN", t),
        // env_remove so an exported token in the developer's shell cannot leak in.
        None => cmd.env_remove("SLASHWORK_TOKEN"),
    };

    let mut child = cmd.spawn().expect("spawn slashwork-offload");
    child
        .stdin
        .take()
        .expect("stdin")
        .write_all(envelope.as_bytes())
        .expect("write envelope");
    let out = child.wait_with_output().expect("wait for hook");
    let _ = std::fs::remove_dir_all(&sandbox);
    assert!(out.status.success(), "hook must always exit 0");
    String::from_utf8(out.stdout).expect("utf8 stdout")
}

#[test]
fn a_non_subagent_tool_is_untouched() {
    let out = hook(
        r#"{"session_id":"s","tool_name":"Bash","tool_input":{"prompt":"ls"}}"#,
        Some("t"),
    );
    assert!(out.is_empty(), "got: {out}");
}

#[test]
fn an_empty_prompt_is_untouched() {
    let out = hook(
        r#"{"session_id":"s","tool_name":"Task","tool_input":{"prompt":""}}"#,
        Some("t"),
    );
    assert!(out.is_empty(), "got: {out}");
}

#[test]
fn our_own_worker_spawn_is_never_reposted() {
    let out = hook(
        r#"{"session_id":"s","tool_name":"Task","tool_input":{"prompt":"task_id: abc\nResearch and compare the options; pros and cons of each."}}"#,
        Some("t"),
    );
    assert!(out.is_empty(), "got: {out}");
}

#[test]
fn without_a_token_the_hook_is_inert() {
    // Routable prompt, but not signed in: no disclosure, no network, no output.
    let out = hook(
        r#"{"session_id":"s","tool_name":"Task","tool_input":{"prompt":"Research and compare the leading rate-limiting approaches; give the pros and cons of each."}}"#,
        None,
    );
    assert!(out.is_empty(), "got: {out}");
}

/// Run the hook with the route log pointed at a real file instead of
/// `/dev/null`, and return `(stdout, route log contents)`. The consent-gate path
/// reaches a verdict without a coordinator (it classifies locally and exits), so
/// this needs no network even though a token is present.
fn hook_with_route_log(envelope: &str, token: &str) -> (String, String) {
    let sandbox = std::env::temp_dir().join(format!(
        "slashwork-hook-rl-test-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    std::fs::create_dir_all(&sandbox).expect("sandbox");
    let log = sandbox.join("route-log.jsonl");

    let mut cmd = Command::new(env!("CARGO_BIN_EXE_slashwork-offload"));
    cmd.arg("hook")
        .env("HOME", &sandbox)
        .env("USERPROFILE", &sandbox)
        .env("SLASHWORK_ROUTE_LOG", &log)
        .env("SLASHWORK_TOKEN", token)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());

    let mut child = cmd.spawn().expect("spawn slashwork-offload");
    child
        .stdin
        .take()
        .expect("stdin")
        .write_all(envelope.as_bytes())
        .expect("write envelope");
    let out = child.wait_with_output().expect("wait for hook");
    assert!(out.status.success(), "hook must always exit 0");
    let logged = std::fs::read_to_string(&log).unwrap_or_default();
    let _ = std::fs::remove_dir_all(&sandbox);
    (String::from_utf8(out.stdout).expect("utf8 stdout"), logged)
}

/// Run the hook against a caller-owned sandbox HOME, so several invocations can
/// share state the way real consoles share a home directory. `base` points the
/// dispatch path somewhere harmless: `http://127.0.0.1:1` is an allowed base
/// (the localhost dev exception) with nothing listening, so a run that gets past
/// the consent gate fails instantly and locally instead of reaching the network.
fn hook_in_home(sandbox: &std::path::Path, session: &str, prompt: &str) -> String {
    let envelope = serde_json::json!({
        "session_id": session,
        "tool_name": "Task",
        "tool_input": { "prompt": prompt },
    })
    .to_string();

    let mut cmd = Command::new(env!("CARGO_BIN_EXE_slashwork-offload"));
    cmd.arg("hook")
        .env("HOME", sandbox)
        .env("USERPROFILE", sandbox)
        .env("SLASHWORK_ROUTE_LOG", "/dev/null")
        .env("SLASHWORK_TOKEN", "t")
        .env("SLASHWORK_BASE_URL", "http://127.0.0.1:1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());

    let mut child = cmd.spawn().expect("spawn slashwork-offload");
    child
        .stdin
        .take()
        .expect("stdin")
        .write_all(envelope.as_bytes())
        .expect("write envelope");
    let out = child.wait_with_output().expect("wait for hook");
    assert!(out.status.success(), "hook must always exit 0");
    String::from_utf8(out.stdout).expect("utf8 stdout")
}

#[test]
fn the_consent_disclosure_is_logged_as_local_because_it_runs_locally() {
    // The first routable spawn of a session prints the disclosure and still runs
    // locally. Logging that as "routed" claimed a route that never happened: it
    // put `{"decision":"routed"}` in the log with no task on the coordinator,
    // which is precisely the signal this log exists to keep honest. The class
    // stays in the detail so the routable-slice analysis loses nothing.
    let envelope = format!(
        r#"{{"session_id":"consent-log-{}","tool_name":"Task","tool_input":{{"prompt":"Research and compare the leading rate-limiting approaches; give the pros and cons of each."}}}}"#,
        std::process::id()
    );
    let (out, logged) = hook_with_route_log(&envelope, "t");

    assert!(
        out.contains("systemMessage"),
        "the disclosure must still be shown: {out}"
    );
    assert!(
        !out.contains("permissionDecision"),
        "the disclosed spawn must still run locally: {out}"
    );
    let line = logged.lines().next().unwrap_or_default();
    assert!(
        line.contains(r#""decision":"local""#),
        "the disclosure runs locally, so the verdict is local: {logged:?}"
    );
    assert!(
        line.contains("research"),
        "the class must survive in the detail for the routable-slice work: {logged:?}"
    );
}

#[test]
fn the_disclosure_is_shown_once_per_user_not_once_per_session() {
    // Keyed per session, the gate was a permanent off switch: nearly every
    // session holds exactly one routable spawn, the disclosure consumes it, and
    // the session ends before anything is routed. Per user it is shown once and
    // then routing runs, in this console and every later one.
    const ROUTABLE: &str =
        "Research and compare the leading rate-limiting approaches; give the pros and cons of each.";
    let sandbox = std::env::temp_dir().join(format!(
        "slashwork-consent-home-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    std::fs::create_dir_all(&sandbox).expect("sandbox");

    let first = hook_in_home(&sandbox, "session-one", ROUTABLE);
    assert!(
        first.contains("systemMessage") && first.contains("routed to the offload network"),
        "the first routable spawn must still disclose: {first}"
    );
    assert!(
        !first.contains("permissionDecision"),
        "the disclosed spawn must still run locally: {first}"
    );
    assert!(
        sandbox.join(".slashwork").join("consent").exists(),
        "consent must be recorded in the state dir, not the temp dir"
    );

    // A brand new session, same user. The disclosure is spent.
    let second = hook_in_home(&sandbox, "session-two", ROUTABLE);
    assert!(
        !second.contains("routed to the offload network"),
        "a new session must not re-disclose and must not spend another spawn: {second}"
    );

    let _ = std::fs::remove_dir_all(&sandbox);
}

#[test]
fn malformed_input_is_not_a_crash() {
    for raw in ["", "not json at all", "{}", "[]", r#"{"tool_name":null}"#] {
        let out = hook(raw, Some("t"));
        assert!(out.is_empty(), "input {raw:?} produced: {out}");
    }
}

/// Run the hook with a route-log capture against an unreachable-but-allowed
/// base, from a caller-built envelope. Returns (stdout, route log).
fn hook_raw_with_log(sandbox: &std::path::Path, envelope: &str) -> (String, String) {
    let log = sandbox.join("route-log.jsonl");
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_slashwork-offload"));
    cmd.arg("hook")
        .env("HOME", sandbox)
        .env("USERPROFILE", sandbox)
        .env("SLASHWORK_ROUTE_LOG", &log)
        .env("SLASHWORK_TOKEN", "t")
        .env("SLASHWORK_BASE_URL", "http://127.0.0.1:1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let mut child = cmd.spawn().expect("spawn slashwork-offload");
    child
        .stdin
        .take()
        .expect("stdin")
        .write_all(envelope.as_bytes())
        .expect("write envelope");
    let out = child.wait_with_output().expect("wait for hook");
    assert!(out.status.success(), "hook must always exit 0");
    let logged = std::fs::read_to_string(&log).unwrap_or_default();
    (String::from_utf8(out.stdout).expect("utf8 stdout"), logged)
}

/// A scratch git repo with an uncommitted change, opted in to bundling.
fn bundling_repo(root: &std::path::Path) -> std::path::PathBuf {
    let repo = root.join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    for args in [
        vec!["init", "-q", "-b", "main"],
        vec!["config", "user.email", "t@t"],
        vec!["config", "user.name", "t"],
    ] {
        assert!(Command::new("git")
            .arg("-C")
            .arg(&repo)
            .args(&args)
            .status()
            .unwrap()
            .success());
    }
    std::fs::write(repo.join("src.rs"), "fn a() {}\n").unwrap();
    for args in [vec!["add", "src.rs"], vec!["commit", "-q", "-m", "init"]] {
        assert!(Command::new("git")
            .arg("-C")
            .arg(&repo)
            .args(&args)
            .status()
            .unwrap()
            .success());
    }
    std::fs::write(repo.join("src.rs"), "fn a() { changed() }\n").unwrap();
    std::fs::write(repo.join(".slashwork-bundle"), "").unwrap();
    repo.canonicalize().unwrap()
}

#[test]
fn a_bundle_eligible_review_reaches_dispatch_after_consent() {
    let sandbox = std::env::temp_dir().join(format!(
        "slashwork-hook-bundle-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::remove_dir_all(&sandbox);
    std::fs::create_dir_all(&sandbox).unwrap();
    let repo = bundling_repo(&sandbox);
    let envelope = serde_json::json!({
        "session_id": "bundle-e2e",
        "tool_name": "Agent",
        "cwd": repo.to_str().unwrap(),
        "tool_input": { "prompt": format!(
            "Review the uncommitted changes in {} for correctness.",
            repo.display()
        ) },
    })
    .to_string();

    // First spawn: bundle-eligible counts as routable for the consent gate, so
    // the disclosure shows and it runs locally.
    let (out, logged) = hook_raw_with_log(&sandbox, &envelope);
    assert!(out.contains("slashwork intercept is on"), "stdout: {out}");
    assert!(
        logged.contains("consent notice shown, routable as review (bundled)"),
        "log: {logged}"
    );

    // Second spawn: past consent, the bundled task is dispatched for real. The
    // base is unreachable, so the proof it got past the classifier (which
    // declines this prompt for its absolute path) is the dispatch-stage reason.
    let (out2, logged2) = hook_raw_with_log(&sandbox, &envelope);
    assert!(out2.is_empty(), "a local fall-through stays silent: {out2}");
    assert!(
        logged2.contains("coordinator unreachable"),
        "log: {logged2}"
    );

    let _ = std::fs::remove_dir_all(&sandbox);
}

#[test]
fn without_the_marker_the_same_spawn_declines_as_before() {
    let sandbox = std::env::temp_dir().join(format!(
        "slashwork-hook-nobundle-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::remove_dir_all(&sandbox);
    std::fs::create_dir_all(&sandbox).unwrap();
    let repo = bundling_repo(&sandbox);
    std::fs::remove_file(repo.join(".slashwork-bundle")).unwrap();
    let envelope = serde_json::json!({
        "session_id": "nobundle-e2e",
        "tool_name": "Agent",
        "cwd": repo.to_str().unwrap(),
        "tool_input": { "prompt": format!(
            "Review the uncommitted changes in {} for correctness.",
            repo.display()
        ) },
    })
    .to_string();
    let (out, logged) = hook_raw_with_log(&sandbox, &envelope);
    assert!(out.is_empty(), "stdout: {out}");
    assert!(logged.contains("local path reference"), "log: {logged}");
    let _ = std::fs::remove_dir_all(&sandbox);
}
