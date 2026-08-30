//! Bundled reviews: make a review-of-repo-work spawn routable by shipping the
//! material with it.
//!
//! The classifier declines any prompt that reaches into the machine, which is
//! correct and also why review spawns (the largest source of subagent token
//! burn) never route: they name a diff, a branch, or a brief file. This module
//! turns an eligible review spawn into a self-contained task: it collects the
//! repo material (a diff the prompt names, else the working-tree diff, else the
//! branch diff, plus any small files the prompt names), rewrites the prompt's
//! absolute paths to repo-relative ones, and hands back a prompt + context
//! bundle pair the coordinator already accepts.
//!
//! Nothing here loosens the classifier. Eligibility is explicit and narrow:
//!
//! - The repo has opted in: a `.slashwork-bundle` file at the git root. Repo
//!   content reaches a stranger's machine, so presence of that file is the
//!   consent, per repo, visible in the tree and committable by a team.
//! - The prompt reads as review work (`review`, `critique`, `assess`,
//!   `evaluate`).
//! - The material fits: the bundle is capped at [`BUNDLE_MAX_BYTES`] and every
//!   inlined file at [`INLINE_FILE_MAX_BYTES`].
//! - The bundle passes the high-precision secret scan (key shapes, not the
//!   prose vocabulary: code diffs legitimately mention "password").
//!
//! Everything else falls through to the local spawn exactly as before.

use crate::classify::secret_key_reason;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::LazyLock;

/// Opt-in marker file at the repo root. Its presence enables bundled reviews
/// for the repo; its content is ignored.
pub const BUNDLE_MARKER: &str = ".slashwork-bundle";

/// Hard cap on the assembled bundle. Measured over four weeks of real review
/// spawns: p50 of a task diff is 4-7KB and 28-30 of every 30 commits fit under
/// 48KB, so this cap admits the population without shipping repo dumps.
pub const BUNDLE_MAX_BYTES: usize = 48 * 1024;

/// Cap per inlined file the prompt names (task briefs, specs).
pub const INLINE_FILE_MAX_BYTES: usize = 16 * 1024;

/// Diff paths never worth shipping: lockfiles and minified bundles carry
/// high-entropy runs that trip the secret scan and say nothing a reviewer
/// needs.
const DIFF_EXCLUDES: &[&str] = &[
    ":(exclude)*.lock",
    ":(exclude)package-lock.json",
    ":(exclude)*.min.js",
    ":(exclude)*.min.css",
];

/// Review-shaped work, matched loosely on purpose: this gate only decides
/// whether bundling is attempted, never whether a prompt is routable.
static REVIEW_INTENT: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r"\b(review|critique|assess|evaluate)\b").unwrap());

/// What bundling decided for one spawn.
#[derive(Debug, PartialEq, Eq)]
pub enum BundleOutcome {
    /// Ship it: the rewritten prompt and the assembled bundle.
    Bundled { prompt: String, bundle: String },
    /// Not bundle material (no marker, not review-shaped, nothing to bundle):
    /// fall through silently to the normal local decline.
    NotEligible,
    /// Bundle material, but it must not leave (over cap, secret-bearing):
    /// run local and log this reason.
    Declined { reason: String },
}

/// Run git in `cwd`, returning stdout only on success.
fn git_out(cwd: &Path, args: &[&str]) -> Option<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(cwd)
        .args(args)
        .output()
        .ok()?;
    if out.status.success() {
        Some(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        None
    }
}

/// The repo root of `cwd`, if it is inside a git work tree.
fn repo_root(cwd: &Path) -> Option<PathBuf> {
    let out = git_out(cwd, &["rev-parse", "--show-toplevel"])?;
    let trimmed = out.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(PathBuf::from(trimmed))
    }
}

/// The uncommitted diff (staged and unstaged, tracked files), or on a clean
/// tree the branch diff against the frozen origin default branch. Lockfiles
/// and minified assets are excluded from both.
fn material_diff(root: &Path) -> Option<String> {
    let mut args = vec!["diff", "HEAD", "--", "."];
    args.extend_from_slice(DIFF_EXCLUDES);
    let working = git_out(root, &args)?;
    if !working.trim().is_empty() {
        return Some(working);
    }
    for base in ["origin/main", "origin/master"] {
        let Some(mb) = git_out(root, &["merge-base", "HEAD", base]) else {
            continue;
        };
        let mb = mb.trim().to_string();
        let mut args = vec!["diff", mb.as_str(), "HEAD", "--", "."];
        args.extend_from_slice(DIFF_EXCLUDES);
        let branch = git_out(root, &args)?;
        if !branch.trim().is_empty() {
            return Some(branch);
        }
    }
    None
}

/// Files the prompt names by absolute path under the repo root, as
/// `(token as written, repo-relative path, content)`. Canonical paths do the
/// matching, so Windows separators and symlinked temp dirs compare correctly;
/// anything missing, outside the root, or over the per-file cap is skipped.
/// Trailing punctuation is trimmed so a path ending a sentence still resolves.
fn named_files(prompt: &str, root: &Path) -> Vec<(String, String, String)> {
    let Ok(root_canon) = root.canonicalize() else {
        return Vec::new();
    };
    let mut seen = Vec::new();
    let mut out = Vec::new();
    for token in prompt.split_whitespace() {
        let token = token.trim_matches(|c: char| ",.;:!?)('\"`".contains(c));
        // Windows prompts mix separators, and the canonical temp dir is a
        // verbatim \\?\ path where a forward slash is not a separator, so
        // the lookup uses a native-separator copy; the rewrite later keeps
        // the token exactly as written.
        let lookup = if cfg!(windows) {
            token.replace('/', "\\")
        } else {
            token.to_string()
        };
        let path = Path::new(&lookup);
        if !path.is_absolute() {
            continue;
        }
        let Ok(canon) = path.canonicalize() else {
            continue;
        };
        let Ok(rel) = canon.strip_prefix(&root_canon) else {
            continue;
        };
        let rel = rel.to_string_lossy().replace('\\', "/");
        if rel.is_empty() || seen.contains(&rel) {
            continue;
        }
        let Ok(meta) = canon.metadata() else { continue };
        if !meta.is_file() || meta.len() > INLINE_FILE_MAX_BYTES as u64 {
            continue;
        }
        let Ok(content) = std::fs::read_to_string(&canon) else {
            continue;
        };
        seen.push(rel.clone());
        out.push((token.to_string(), rel, content));
    }
    out
}

/// Try to turn a review spawn into a prompt + bundle pair. See the module docs
/// for the eligibility rules; anything ineligible falls through untouched.
#[must_use]
pub fn bundle_review(prompt: &str, cwd: &Path) -> BundleOutcome {
    let Some(root) = repo_root(cwd) else {
        return BundleOutcome::NotEligible;
    };
    if !root.join(BUNDLE_MARKER).exists() {
        return BundleOutcome::NotEligible;
    }
    if !REVIEW_INTENT.is_match(&prompt.to_lowercase()) {
        return BundleOutcome::NotEligible;
    }
    let files = named_files(prompt, &root);

    // A diff the prompt names is the material the review is actually about.
    // Prefer it: the branch diff is everything since the base, so it grows with
    // every task that landed before this one and buries the change under review
    // (and on a plan of any length, pushes the bundle over the cap).
    let named_diff = files
        .iter()
        .find(|(_, rel, _)| {
            Path::new(rel.as_str()).extension().is_some_and(|ext| {
                ext.eq_ignore_ascii_case("diff") || ext.eq_ignore_ascii_case("patch")
            })
        })
        .map(|(_, rel, content)| (rel.clone(), content.clone()));

    let diff = if let Some((_, content)) = &named_diff {
        content.clone()
    } else {
        let Some(material) = material_diff(&root) else {
            return BundleOutcome::NotEligible;
        };
        material
    };

    let mut bundle = String::from("=== diff ===\n");
    bundle.push_str(&diff);
    for (_, rel, content) in &files {
        // The named diff became the material above; do not ship it twice.
        if named_diff.as_ref().is_some_and(|(r, _)| r == rel) {
            continue;
        }
        let _ = write!(bundle, "\n=== file: {rel} ===\n{content}");
    }
    if bundle.len() > BUNDLE_MAX_BYTES {
        return BundleOutcome::Declined {
            reason: format!(
                "bundle over the {}KB cap ({} bytes)",
                BUNDLE_MAX_BYTES / 1024,
                bundle.len()
            ),
        };
    }

    // Named paths become repo-relative by exact-token replacement (so Windows
    // separators rewrite correctly), then leftover absolute references under
    // the root are made relative too: the prompt must make sense against the
    // bundle instead of against this machine.
    let mut rewritten = prompt.to_string();
    for (token, rel, _) in &files {
        rewritten = rewritten.replace(token, &format!("./{rel}"));
    }
    rewritten = rewritten.replace(&format!("{}/", root.display()), "./");

    // Keys-only secret scan over everything that would leave. The prose
    // vocabulary stays prompt-classifier territory: a diff of an auth module
    // saying "password" is exactly what a review is for.
    for text in [bundle.as_str(), rewritten.as_str()] {
        if let Some(what) = secret_key_reason(text) {
            return BundleOutcome::Declined {
                reason: format!("bundle carries a {what}"),
            };
        }
    }

    BundleOutcome::Bundled {
        prompt: rewritten,
        bundle,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// A scratch git repo with one committed file, identity configured so
    /// commits work on CI.
    fn repo() -> tempdir::Scratch {
        let dir = tempdir::Scratch::new();
        git(dir.path(), &["init", "-q", "-b", "main"]);
        git(dir.path(), &["config", "user.email", "t@t"]);
        git(dir.path(), &["config", "user.name", "t"]);
        fs::write(dir.path().join("src.rs"), "fn a() {}\n").unwrap();
        git(dir.path(), &["add", "src.rs"]);
        git(dir.path(), &["commit", "-q", "-m", "init"]);
        dir
    }

    fn git(cwd: &Path, args: &[&str]) {
        let out = Command::new("git")
            .arg("-C")
            .arg(cwd)
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    fn opt_in(dir: &Path) {
        fs::write(dir.join(BUNDLE_MARKER), "").unwrap();
    }

    /// Minimal self-cleaning temp dirs without a dev-dependency.
    mod tempdir {
        pub struct Scratch(std::path::PathBuf);
        impl Scratch {
            pub fn new() -> Self {
                let p = std::env::temp_dir().join(format!(
                    "swbundle-{}-{:?}",
                    std::process::id(),
                    std::thread::current().id()
                ));
                let _ = std::fs::remove_dir_all(&p);
                std::fs::create_dir_all(&p).unwrap();
                Self(p.canonicalize().unwrap())
            }
            pub fn path(&self) -> &std::path::Path {
                &self.0
            }
        }
        impl Drop for Scratch {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
    }

    const REVIEW_PROMPT: &str =
        "Review the changes on this branch for correctness and spec compliance.";

    #[test]
    fn without_the_marker_nothing_is_bundled() {
        let dir = repo();
        fs::write(dir.path().join("src.rs"), "fn a() { b() }\n").unwrap();
        assert_eq!(
            bundle_review(REVIEW_PROMPT, dir.path()),
            BundleOutcome::NotEligible
        );
    }

    #[test]
    fn a_non_review_prompt_is_not_bundle_material() {
        let dir = repo();
        opt_in(dir.path());
        fs::write(dir.path().join("src.rs"), "fn a() { b() }\n").unwrap();
        assert_eq!(
            bundle_review("Implement the parser described in the brief.", dir.path()),
            BundleOutcome::NotEligible
        );
    }

    #[test]
    fn outside_a_git_repo_nothing_is_bundled() {
        let dir = tempdir::Scratch::new();
        assert_eq!(
            bundle_review(REVIEW_PROMPT, dir.path()),
            BundleOutcome::NotEligible
        );
    }

    #[test]
    fn bundles_the_working_tree_diff() {
        let dir = repo();
        opt_in(dir.path());
        fs::write(dir.path().join("src.rs"), "fn a() { changed_call() }\n").unwrap();
        match bundle_review(REVIEW_PROMPT, dir.path()) {
            BundleOutcome::Bundled { prompt, bundle } => {
                assert_eq!(prompt, REVIEW_PROMPT);
                assert!(bundle.contains("changed_call"), "bundle: {bundle}");
                assert!(bundle.contains("diff --git"), "bundle: {bundle}");
            }
            other => panic!("expected Bundled, got {other:?}"),
        }
    }

    #[test]
    fn a_clean_tree_bundles_the_branch_diff_against_origin_main() {
        let dir = repo();
        opt_in(dir.path());
        // Freeze "origin/main" at the initial commit, then commit branch work.
        let head = Command::new("git")
            .args(["-C", dir.path().to_str().unwrap(), "rev-parse", "HEAD"])
            .output()
            .unwrap();
        let base = String::from_utf8(head.stdout).unwrap().trim().to_string();
        git(
            dir.path(),
            &["update-ref", "refs/remotes/origin/main", &base],
        );
        fs::write(dir.path().join("src.rs"), "fn a() { branch_work() }\n").unwrap();
        git(dir.path(), &["add", "src.rs"]);
        git(dir.path(), &["commit", "-q", "-m", "task work"]);
        match bundle_review(REVIEW_PROMPT, dir.path()) {
            BundleOutcome::Bundled { bundle, .. } => {
                assert!(bundle.contains("branch_work"), "bundle: {bundle}");
            }
            other => panic!("expected Bundled, got {other:?}"),
        }
    }

    #[test]
    fn a_named_diff_file_replaces_the_branch_diff() {
        let dir = repo();
        opt_in(dir.path());
        // Freeze "origin/main" at the initial commit, then commit work from an
        // earlier task. The branch diff now carries material this review is
        // not about, which is what the named diff has to displace.
        let head = Command::new("git")
            .args(["-C", dir.path().to_str().unwrap(), "rev-parse", "HEAD"])
            .output()
            .unwrap();
        let base = String::from_utf8(head.stdout).unwrap().trim().to_string();
        git(
            dir.path(),
            &["update-ref", "refs/remotes/origin/main", &base],
        );
        fs::write(
            dir.path().join("src.rs"),
            "fn a() { earlier_task_work() }\n",
        )
        .unwrap();
        git(dir.path(), &["add", "src.rs"]);
        git(dir.path(), &["commit", "-q", "-m", "earlier task"]);
        fs::write(
            dir.path().join("review-task7.diff"),
            "--- a/src.rs\n+++ b/src.rs\n@@\n+fn this_task_only() {}\n",
        )
        .unwrap();
        let prompt = format!(
            "Review this task against its brief. The diff: {}/review-task7.diff",
            dir.path().display()
        );
        match bundle_review(&prompt, dir.path()) {
            BundleOutcome::Bundled { bundle, .. } => {
                assert!(bundle.contains("this_task_only"), "bundle: {bundle}");
                assert!(
                    !bundle.contains("earlier_task_work"),
                    "branch diff should have been displaced: {bundle}"
                );
            }
            other => panic!("expected Bundled, got {other:?}"),
        }
    }

    #[test]
    fn a_clean_tree_with_no_branch_work_is_not_eligible() {
        let dir = repo();
        opt_in(dir.path());
        assert_eq!(
            bundle_review(REVIEW_PROMPT, dir.path()),
            BundleOutcome::NotEligible
        );
    }

    #[test]
    fn inlines_a_small_file_the_prompt_names_and_rewrites_its_path() {
        let dir = repo();
        opt_in(dir.path());
        fs::create_dir_all(dir.path().join("docs")).unwrap();
        fs::write(
            dir.path().join("docs/brief.md"),
            "# Task 3 brief\nExact tests listed here.\n",
        )
        .unwrap();
        fs::write(dir.path().join("src.rs"), "fn a() { changed_call() }\n").unwrap();
        let prompt = format!(
            "Review one task: spec compliance. Brief: {}/docs/brief.md",
            dir.path().display()
        );
        match bundle_review(&prompt, dir.path()) {
            BundleOutcome::Bundled { prompt, bundle } => {
                assert!(
                    bundle.contains("Exact tests listed here"),
                    "bundle: {bundle}"
                );
                assert!(bundle.contains("docs/brief.md"), "bundle: {bundle}");
                assert!(prompt.contains("./docs/brief.md"), "prompt: {prompt}");
                assert!(
                    !prompt.contains("/swbundle-"),
                    "prompt still absolute: {prompt}"
                );
            }
            other => panic!("expected Bundled, got {other:?}"),
        }
    }

    #[test]
    fn declines_when_the_material_is_over_the_cap() {
        let dir = repo();
        opt_in(dir.path());
        let big = "x".repeat(BUNDLE_MAX_BYTES + 4096);
        fs::write(dir.path().join("src.rs"), big).unwrap();
        match bundle_review(REVIEW_PROMPT, dir.path()) {
            BundleOutcome::Declined { reason } => {
                assert!(reason.contains("cap"), "reason: {reason}");
            }
            other => panic!("expected Declined, got {other:?}"),
        }
    }

    #[test]
    fn declines_a_secret_shaped_token_in_the_diff() {
        let dir = repo();
        opt_in(dir.path());
        fs::write(
            dir.path().join("src.rs"),
            "fn a() { let t = \"ghp_abcdefghijklmnop\"; }\n",
        )
        .unwrap();
        match bundle_review(REVIEW_PROMPT, dir.path()) {
            BundleOutcome::Declined { reason } => {
                assert!(reason.contains("secret"), "reason: {reason}");
            }
            other => panic!("expected Declined, got {other:?}"),
        }
    }

    #[test]
    fn lockfile_only_changes_leave_nothing_to_bundle() {
        let dir = repo();
        opt_in(dir.path());
        fs::write(dir.path().join("Cargo.lock"), "x".repeat(2000)).unwrap();
        git(dir.path(), &["add", "Cargo.lock"]);
        git(dir.path(), &["commit", "-q", "-m", "lockfile"]);
        fs::write(dir.path().join("Cargo.lock"), "y".repeat(2000)).unwrap();
        assert_eq!(
            bundle_review(REVIEW_PROMPT, dir.path()),
            BundleOutcome::NotEligible
        );
    }
}
