//! End-to-end check of the `classify` subcommand: pipe a route envelope to the
//! real binary and assert the JSON verdict. The classifier logic itself is
//! unit-tested in `classify.rs`; this covers the CLI wiring (read stdin ->
//! classify -> print verdict -> exit 0) that the harness hooks depend on.

use std::io::Write;
use std::process::{Command, Stdio};

/// Run `slashwork-offload classify` with `envelope` on stdin, returning stdout.
/// Asserts the process exited 0 (the classify path must never fail).
fn classify(envelope: &str) -> String {
    let mut child = Command::new(env!("CARGO_BIN_EXE_slashwork-offload"))
        .arg("classify")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn slashwork-offload");
    child
        .stdin
        .take()
        .expect("stdin")
        .write_all(envelope.as_bytes())
        .expect("write envelope");
    let out = child.wait_with_output().expect("wait for classify");
    assert!(out.status.success(), "classify must always exit 0");
    String::from_utf8(out.stdout).expect("utf8 stdout")
}

#[test]
fn routable_prompt_reports_its_class() {
    let out = classify(
        r#"{"harness":"claude-code","spawn":{"prompt":"Research and compare the leading rate-limiting approaches; give the pros and cons of each."}}"#,
    );
    assert!(out.contains(r#""decision":"routable""#), "got: {out}");
    assert!(out.contains(r#""class":"research""#), "got: {out}");
}

#[test]
fn local_prompt_reports_a_reason() {
    let out = classify(
        r#"{"harness":"claude-code","spawn":{"prompt":"Refactor the function in ./src/main.rs and run the tests."}}"#,
    );
    assert!(out.contains(r#""decision":"local""#), "got: {out}");
    assert!(out.contains(r#""reason""#), "got: {out}");
}

#[test]
fn self_worker_marker_is_local() {
    let out = classify(
        r#"{"harness":"claude-code","spawn":{"prompt":"task_id: 123\nResearch and compare the options; pros and cons of each."}}"#,
    );
    assert!(out.contains(r#""decision":"local""#), "got: {out}");
    assert!(out.contains("self-worker"), "got: {out}");
}

#[test]
fn empty_input_is_local_not_a_crash() {
    let out = classify("");
    assert!(out.contains(r#""decision":"local""#), "got: {out}");
}
