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
/// needs, and the opt-in marker is this feature's own plumbing. The marker is
/// usually untracked (opting in does not require committing it), so without
/// this it would ride along in every bundle. Keep in step with
/// [`BUNDLE_MARKER`].
const DIFF_EXCLUDES: &[&str] = &[
    ":(exclude)*.lock",
    ":(exclude)package-lock.json",
    ":(exclude)*.min.js",
    ":(exclude)*.min.css",
    ":(exclude).slashwork-bundle",
];

/// Review-shaped work, matched loosely on purpose: this gate only decides
/// whether bundling is attempted, never whether a prompt is routable.
///
/// Inflections count. A reviewer prompt assigns the role in the participle
/// ("you are reviewing one task", "you are the task reviewer") far more often
/// than it uses the bare stem, and `\breview\b` matches neither, so the shape
/// this gate exists to catch was the shape it missed.
static REVIEW_INTENT: LazyLock<regex::Regex> = LazyLock::new(|| {
    regex::Regex::new(r"(?i)\b(review(s|ed|er|ers|ing)?|critiqu(e|es|ed|ing)|assess(es|ed|ing|ment)?|evaluat(e|es|ed|ing|ion))\b")
        .unwrap()
});

/// Work that CHANGES the repo, which is never bundle material however much
/// review vocabulary it carries.
///
/// Review words are not evidence of a review. An implementation prompt
/// routinely describes the review that will follow it ("a separate reviewer
/// runs after you report", "this work must be reviewed first"), quotes a
/// finding from an earlier one, or just names a component `review-dock`. On
/// four weeks of real spawns the bare-vocabulary gate admitted 59 mutation
/// tasks for every 108 it got right, and admitting one is the worst outcome
/// this plugin has: the offloader asked for Task 3 to be implemented, the
/// network answers with a written review, the hook substitutes it for the
/// local spawn, and the work silently never happens.
///
/// So the role decides, not the vocabulary: an implementer is told what to
/// change, a reviewer is told what to produce. This gate only ever REMOVES
/// eligibility. A prompt it vetoes runs locally exactly as it did before
/// bundling existed, which is why it is broad and the review gate stays narrow:
/// a false veto costs the tokens that spawn always cost, a false admission
/// costs the user their task.
static MUTATION_ROLE: LazyLock<regex::Regex> = LazyLock::new(|| {
    regex::Regex::new(
        r"(?i)\byou are (implementing|building|creating|writing|refactoring|restyling|migrating|applying|fixing|closing out|adding|updating|porting|wiring)\b|\byou are the [a-z-]* ?implementer\b|\byou are (running|applying) (the |a |single |scoped )*fix wave\b|\byour task is to (implement|add|fix|write|create|update|refactor|build)\b|\bimplement task \d|\bcommit your work\b|\bopen a (pr|pull request)\b|\bdo not create or switch branches\b",
    )
    .unwrap()
});

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
    /// Everything about this spawn qualifies except the repo's consent: it is
    /// review work with material to ship, in a repo that has never opted in.
    /// The hook says so once per repo, because the alternative is what shipped
    /// first: a feature that is off by default, invisible when it declines, and
    /// therefore enabled nowhere.
    NotOptedIn { repo: PathBuf },
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

/// Unified diffs for the files that exist only in the working tree.
///
/// `git diff HEAD` reports tracked changes only, so a task that just ADDS
/// files reads as a clean tree and falls through to the branch diff, which on
/// a long-lived branch is both the wrong material and usually over the cap.
/// `--exclude-standard` applies `.gitignore`, so an ignored file never ships,
/// and the real index is never touched: these diffs are synthesized here
/// rather than staged with `add --intent-to-add`.
///
/// Anything over [`INLINE_FILE_MAX_BYTES`] or not valid UTF-8 is skipped.
/// Neither is review material, and one large stray file would push an
/// otherwise fine bundle over the cap.
fn untracked_diff(root: &Path) -> String {
    let mut args = vec!["ls-files", "--others", "--exclude-standard", "--", "."];
    args.extend_from_slice(DIFF_EXCLUDES);
    let Some(list) = git_out(root, &args) else {
        return String::new();
    };
    let mut out = String::new();
    for rel in list.lines().map(str::trim).filter(|l| !l.is_empty()) {
        let path = root.join(rel);
        let Ok(meta) = path.metadata() else { continue };
        if !meta.is_file() || meta.len() > INLINE_FILE_MAX_BYTES as u64 {
            continue;
        }
        let Ok(content) = std::fs::read_to_string(&path) else {
            continue;
        };
        let _ = write!(
            out,
            "diff --git a/{rel} b/{rel}\nnew file mode 100644\n--- /dev/null\n+++ b/{rel}\n@@ -0,0 +1,{} @@\n",
            content.lines().count()
        );
        for line in content.lines() {
            let _ = writeln!(out, "+{line}");
        }
    }
    out
}

/// The uncommitted diff (tracked changes plus files that exist only in the
/// working tree), or on a genuinely clean tree the branch diff against the
/// frozen origin default branch. Lockfiles and minified assets are excluded
/// from all of them.
fn material_diff(root: &Path) -> Option<String> {
    let mut args = vec!["diff", "HEAD", "--", "."];
    args.extend_from_slice(DIFF_EXCLUDES);
    let mut working = git_out(root, &args)?;
    working.push_str(&untracked_diff(root));
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

/// Trim a unified diff to `budget` bytes by dropping whole per-file sections.
///
/// A section runs from a `diff --git a/PATH b/PATH` line to the next one (or
/// the end), and its path is the text after the final ` b/` on that header.
/// Anything before the first header is a preamble, kept whenever it fits.
///
/// Sections are selected smallest first, so the result holds the greatest
/// number of complete files, and are emitted in their original input order. A
/// section is never emitted partially: half a hunk is worse than no hunk,
/// because a reviewer cannot tell the difference between code that is absent
/// and code that was cut. When anything is dropped the diff ends with a notice
/// naming what went, so the reviewer knows the material is partial, and the
/// whole string including that notice still fits `budget`.
fn trim_diff(diff: &str, budget: usize) -> (String, Vec<String>) {
    fn header_path(line: &str) -> String {
        let header = line.trim_end_matches(['\n', '\r']);
        if let Some((_, path)) = header.rsplit_once(" b/") {
            return path.to_owned();
        }
        header.trim_start_matches("diff --git ").to_owned()
    }

    fn omission_notice(paths: &[String]) -> String {
        format!(
            "\n=== {} files omitted to fit the size limit: {} ===\n",
            paths.len(),
            paths.join(", ")
        )
    }

    if diff.len() <= budget {
        return (diff.to_owned(), Vec::new());
    }

    // `split_inclusive` keeps the terminators, so preamble and bodies
    // concatenate back to the exact input and every boundary is a char boundary.
    let mut preamble = String::new();
    let mut paths: Vec<String> = Vec::new();
    let mut bodies: Vec<String> = Vec::new();
    for line in diff.split_inclusive('\n') {
        if line.starts_with("diff --git ") {
            paths.push(header_path(line));
            bodies.push(line.to_owned());
        } else if let Some(current) = bodies.last_mut() {
            current.push_str(line);
        } else {
            preamble.push_str(line);
        }
    }

    // No header anywhere: one anonymous section, already over budget.
    if bodies.is_empty() {
        return (String::new(), Vec::new());
    }
    if preamble.len() > budget {
        return (String::new(), paths);
    }

    // Smallest first; `sort_by_key` is stable, so ties keep input order.
    let mut by_size: Vec<(usize, usize)> = bodies.iter().map(String::len).enumerate().collect();
    by_size.sort_by_key(|&(_, len)| len);
    let mut smallest_k = Vec::with_capacity(by_size.len() + 1);
    smallest_k.push(0usize);
    let mut running = 0usize;
    for &(_, len) in &by_size {
        running += len;
        smallest_k.push(running);
    }

    // Keeping one more section costs bytes but shortens the notice, so
    // feasibility is not monotone. Walk down from "keep everything" and take
    // the first fit: the most whole files that can be kept.
    for keep in (1..=by_size.len()).rev() {
        let Some(&used) = smallest_k.get(keep) else {
            continue;
        };
        let mut dropped_idx: Vec<usize> = by_size.iter().skip(keep).map(|&(i, _)| i).collect();
        dropped_idx.sort_unstable();
        let dropped: Vec<String> = dropped_idx
            .iter()
            .filter_map(|&i| paths.get(i).cloned())
            .collect();
        let notice = if dropped.is_empty() {
            String::new()
        } else {
            omission_notice(&dropped)
        };
        let total = preamble.len() + used + notice.len();
        if total > budget {
            continue;
        }
        let mut kept_idx: Vec<usize> = by_size.iter().take(keep).map(|&(i, _)| i).collect();
        kept_idx.sort_unstable();
        let mut out = String::with_capacity(total);
        out.push_str(&preamble);
        for i in kept_idx {
            if let Some(body) = bodies.get(i) {
                out.push_str(body);
            }
        }
        out.push_str(&notice);
        return (out, dropped);
    }
    (String::new(), paths)
}

/// Assemble the bundle from a diff and the files the prompt named. Split out so
/// the trim path re-assembles exactly what the first pass did.
fn rebuild(
    diff: &str,
    files: &[(String, String, String)],
    named_diff: Option<&(String, String)>,
) -> String {
    let mut bundle = String::from("=== diff ===\n");
    bundle.push_str(diff);
    for (_, rel, content) in files {
        // The named diff became the material above; do not ship it twice.
        if named_diff.is_some_and(|(r, _)| r == rel) {
            continue;
        }
        let _ = write!(bundle, "\n=== file: {rel} ===\n{content}");
    }
    bundle
}

/// Try to turn a review spawn into a prompt + bundle pair. See the module docs
/// for the eligibility rules; anything ineligible falls through untouched.
#[must_use]
pub fn bundle_review(prompt: &str, cwd: &Path) -> BundleOutcome {
    let Some(root) = repo_root(cwd) else {
        return BundleOutcome::NotEligible;
    };
    // The veto runs first: a prompt that says both ("implement Task 3, a
    // reviewer follows") is implementation work, and shipping it as a review
    // would answer the wrong question.
    if MUTATION_ROLE.is_match(prompt) || !REVIEW_INTENT.is_match(prompt) {
        return BundleOutcome::NotEligible;
    }
    // The consent check comes after the shape checks, not before, so a repo
    // that has not opted in can still be told that this spawn would have
    // routed. Collecting the material to prove it costs a git call, so it
    // happens only for a spawn that has already passed every other gate.
    let opted_in = root.join(BUNDLE_MARKER).exists();
    if !opted_in && material_diff(&root).is_none() {
        return BundleOutcome::NotEligible;
    }
    if !opted_in {
        return BundleOutcome::NotOptedIn { repo: root };
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

    let mut bundle = rebuild(&diff, &files, named_diff.as_ref());
    // Over the cap, drop whole files from the diff until it fits rather than
    // discarding the bundle. All-or-nothing threw away every review whose task
    // happened to touch one large file, and on a branch carrying more than one
    // task's work that was most of them. What survives is whole files plus a
    // notice naming what went, so a partial review is visibly partial.
    if bundle.len() > BUNDLE_MAX_BYTES {
        let overhead = bundle.len() - diff.len();
        let budget = BUNDLE_MAX_BYTES.saturating_sub(overhead);
        let (trimmed, _dropped) = trim_diff(&diff, budget);
        if trimmed.trim().is_empty() {
            return BundleOutcome::Declined {
                reason: format!(
                    "bundle over the {}KB cap ({} bytes) and nothing whole fits",
                    BUNDLE_MAX_BYTES / 1024,
                    bundle.len()
                ),
            };
        }
        bundle = rebuild(&trimmed, &files, named_diff.as_ref());
        debug_assert!(bundle.len() <= BUNDLE_MAX_BYTES);
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

    /// Without the marker nothing is bundled, but the outcome says why: the
    /// repo has material and never opted in, which is the one decline the user
    /// can act on.
    #[test]
    fn without_the_marker_nothing_is_bundled() {
        let dir = repo();
        fs::write(dir.path().join("src.rs"), "fn a() { b() }\n").unwrap();
        match bundle_review(REVIEW_PROMPT, dir.path()) {
            BundleOutcome::NotOptedIn { repo } => assert_eq!(repo, dir.path()),
            other => panic!("expected NotOptedIn, got {other:?}"),
        }
    }

    /// An un-opted-in repo with nothing to review stays silent: there is
    /// nothing to offer, so there is nothing to nudge about.
    #[test]
    fn a_clean_un_opted_in_repo_is_not_a_nudge() {
        let dir = repo();
        assert_eq!(
            bundle_review(REVIEW_PROMPT, dir.path()),
            BundleOutcome::NotEligible
        );
    }

    /// The veto still wins over the nudge: implementation work in an
    /// un-opted-in repo must not advertise a feature that would answer it
    /// with a review.
    #[test]
    fn implementation_work_never_nudges() {
        let dir = repo();
        fs::write(dir.path().join("src.rs"), "fn a() { b() }\n").unwrap();
        assert_eq!(
            bundle_review(
                "You are implementing Task 3. A reviewer runs after you report.",
                dir.path()
            ),
            BundleOutcome::NotEligible
        );
    }

    /// The vocabulary test cannot separate these: an implementation prompt
    /// routinely describes the review that will follow it. Sending one to the
    /// network answers "implement Task 3" with a written review and the work
    /// never happens, so the role has to decide, not the words.
    #[test]
    fn an_implementation_prompt_that_mentions_review_is_not_material() {
        let dir = repo();
        opt_in(dir.path());
        fs::write(dir.path().join("src.rs"), "fn a() { b() }\n").unwrap();
        assert_eq!(
            bundle_review(
                "You are implementing Task 3 of an 11-task plan. A review of Task 2 \
                 found a gap. Do not dispatch subagents of your own, not helpers and \
                 not a reviewer. A separate reviewer runs after you report.",
                dir.path()
            ),
            BundleOutcome::NotEligible
        );
    }

    #[test]
    fn a_fix_wave_is_not_bundle_material() {
        let dir = repo();
        opt_in(dir.path());
        fs::write(dir.path().join("src.rs"), "fn a() { b() }\n").unwrap();
        assert_eq!(
            bundle_review(
                "You are fixing the findings from the final review of the \
                 `cli-integration` branch. This is the last gate before merge.",
                dir.path()
            ),
            BundleOutcome::NotEligible
        );
    }

    /// The mirror image: a real review names the implementation it is reviewing,
    /// and must still bundle.
    #[test]
    fn a_review_of_implementation_work_is_still_material() {
        let dir = repo();
        opt_in(dir.path());
        fs::write(dir.path().join("src.rs"), "fn a() { changed() }\n").unwrap();
        assert!(matches!(
            bundle_review(
                "You are reviewing one task of a 14-task implementation plan. \
                 Produce two verdicts: spec compliance and task quality. \
                 Do not modify any file.",
                dir.path()
            ),
            BundleOutcome::Bundled { .. }
        ));
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

    /// Freeze `origin/main` at HEAD, then commit work on top, so the branch
    /// diff carries `earlier_task_work` and the tree is clean.
    fn branch_with_earlier_work(dir: &Path) {
        let head = Command::new("git")
            .args(["-C", dir.to_str().unwrap(), "rev-parse", "HEAD"])
            .output()
            .unwrap();
        let base = String::from_utf8(head.stdout).unwrap().trim().to_string();
        git(dir, &["update-ref", "refs/remotes/origin/main", &base]);
        fs::write(dir.join("src.rs"), "fn a() { earlier_task_work() }\n").unwrap();
        git(dir, &["add", "src.rs"]);
        git(dir, &["commit", "-q", "-m", "earlier task"]);
    }

    #[test]
    fn a_new_untracked_file_is_material() {
        let dir = repo();
        opt_in(dir.path());
        branch_with_earlier_work(dir.path());
        // The task under review only ADDS a file. `git diff HEAD` cannot see
        // it, so without help this reads as a clean tree.
        fs::write(
            dir.path().join("added.rs"),
            "fn brand_new_work() { todo!() }\n",
        )
        .unwrap();
        match bundle_review(REVIEW_PROMPT, dir.path()) {
            BundleOutcome::Bundled { bundle, .. } => {
                assert!(bundle.contains("brand_new_work"), "bundle: {bundle}");
                assert!(bundle.contains("added.rs"), "bundle: {bundle}");
                assert!(
                    !bundle.contains("earlier_task_work"),
                    "fell through to the branch diff: {bundle}"
                );
            }
            other => panic!("expected Bundled, got {other:?}"),
        }
    }

    #[test]
    fn the_opt_in_marker_is_not_review_material() {
        // The marker is usually untracked, so once untracked files became
        // material it would otherwise ride along in every single bundle.
        let dir = repo();
        opt_in(dir.path());
        fs::write(dir.path().join("added.rs"), "fn shipped() {}\n").unwrap();
        match bundle_review(REVIEW_PROMPT, dir.path()) {
            BundleOutcome::Bundled { bundle, .. } => {
                assert!(bundle.contains("shipped"), "bundle: {bundle}");
                assert!(
                    !bundle.contains(BUNDLE_MARKER),
                    "the marker shipped: {bundle}"
                );
            }
            other => panic!("expected Bundled, got {other:?}"),
        }
    }

    #[test]
    fn gitignored_files_never_reach_the_bundle() {
        let dir = repo();
        opt_in(dir.path());
        fs::write(dir.path().join(".gitignore"), "secrets.txt\n").unwrap();
        git(dir.path(), &["add", ".gitignore"]);
        git(dir.path(), &["commit", "-q", "-m", "ignore"]);
        fs::write(dir.path().join("secrets.txt"), "hunter2_do_not_ship\n").unwrap();
        fs::write(dir.path().join("added.rs"), "fn shipped() {}\n").unwrap();
        match bundle_review(REVIEW_PROMPT, dir.path()) {
            BundleOutcome::Bundled { bundle, .. } => {
                assert!(bundle.contains("shipped"), "bundle: {bundle}");
                assert!(
                    !bundle.contains("hunter2_do_not_ship"),
                    "ignored file leaked: {bundle}"
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

    /// Over the cap, the bundle used to be thrown away whole, so a task with
    /// one oversized file in it lost the review of every other file too. Keep
    /// what fits and say what did not.
    #[test]
    fn trims_to_fit_instead_of_discarding_the_whole_bundle() {
        let dir = repo();
        opt_in(dir.path());
        // Tracked, so the oversize lands in `git diff HEAD` rather than being
        // filtered out as an untracked add.
        fs::write(dir.path().join("huge.rs"), "seed\n").unwrap();
        git(dir.path(), &["add", "huge.rs"]);
        git(dir.path(), &["commit", "-q", "-m", "seed huge"]);
        fs::write(dir.path().join("small_a.rs"), "fn a() { changed() }\n").unwrap();
        fs::write(dir.path().join("small_b.rs"), "fn b() { changed() }\n").unwrap();
        let mut huge = String::new();
        for i in 0..(BUNDLE_MAX_BYTES / 8) {
            let _ = writeln!(huge, "line {i}");
        }
        fs::write(dir.path().join("huge.rs"), huge).unwrap();
        match bundle_review(REVIEW_PROMPT, dir.path()) {
            BundleOutcome::Bundled { bundle, .. } => {
                assert!(bundle.len() <= BUNDLE_MAX_BYTES, "len {}", bundle.len());
                assert!(bundle.contains("small_a.rs"), "kept the small files");
                assert!(bundle.contains("small_b.rs"), "kept the small files");
                assert!(
                    bundle.contains("omitted to fit the size limit: huge.rs"),
                    "names what it dropped: {bundle}"
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
