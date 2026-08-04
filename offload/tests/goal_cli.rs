//! End-to-end check of the `goal` subcommand. The parser is unit-tested in
//! `earn.rs`; this pins the JSON shape and exit codes that both harness
//! adapters' earn loops read, so a change here cannot silently break them.

use std::process::Command;

/// Run `slashwork-offload goal <args>`, returning `(exit code, stdout)`.
fn goal(args: &[&str]) -> (i32, String) {
    let out = Command::new(env!("CARGO_BIN_EXE_slashwork-offload"))
        .arg("goal")
        .args(args)
        .output()
        .expect("run slashwork-offload goal");
    (
        out.status.code().unwrap_or(-1),
        String::from_utf8(out.stdout).expect("utf8 stdout"),
    )
}

#[test]
fn time_goal_reports_seconds() {
    let (code, out) = goal(&["30m"]);
    assert_eq!(code, 0);
    assert!(out.contains(r#""mode":"time""#), "got: {out}");
    assert!(out.contains(r#""seconds":1800"#), "got: {out}");
}

#[test]
fn credits_goal_reports_target_and_ceiling() {
    let (code, out) = goal(&["200cr"]);
    assert_eq!(code, 0);
    assert!(out.contains(r#""mode":"credits""#), "got: {out}");
    assert!(out.contains(r#""target":200"#), "got: {out}");
    // The ceiling is what stops a credits goal running forever on a cold pool.
    assert!(out.contains(r#""ceiling_seconds":86400"#), "got: {out}");
}

#[test]
fn a_bad_goal_is_a_usage_error_not_an_unbounded_run() {
    let (code, out) = goal(&["forever"]);
    assert_eq!(code, 2, "bad goals must exit with the usage code");
    assert!(out.is_empty(), "nothing on stdout to misparse: {out}");
}

#[test]
fn a_missing_goal_is_a_usage_error() {
    let (code, _) = goal(&[]);
    assert_eq!(code, 2);
}
