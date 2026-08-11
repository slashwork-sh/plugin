//! Reading local files into a task's `context_bundle`.
//!
//! The classifier declines any prompt that names a path, because v1 sent the
//! prompt as the whole payload and a stranger's session has no repo behind it.
//! This module is the other half: for a `review` prompt, read what it names and
//! ship the contents, so the earner has the material the prompt is about.
//!
//! The classifier stays pure and I/O-free. Every filesystem touch is here.
//!
//! Conservative in the same direction as the classifier: any doubt refuses the
//! whole task to a local spawn. A partial bundle is worse than no bundle,
//! because an earner working from half the material returns a confidently wrong
//! artifact instead of nothing.

use regex::Regex;
use std::sync::LazyLock;

/// A path token with at least one separator: absolute, `~`-rooted, `./`, `../`,
/// or a bare relative path like `src/main.rs`. Deliberately does not require a
/// known extension, because a diff may be named `range` with none.
static SLASHED: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?:~|\.{1,2})?/[A-Za-z0-9._+-]+(?:/[A-Za-z0-9._+-]+)*").unwrap());

/// Characters that end an English sentence but not a filename.
const TRIM: &[char] = &[',', '.', ';', ':', ')', '(', '`', '\'', '"', '!', '?'];

/// Walk `start` back over a run of path characters (matching `SLASHED`'s own
/// character class) so a bare word directly touching the separator, like
/// `requests` in `requests/second`, joins the match instead of being cut at the
/// slash. Only ASCII bytes are in that class, so a non-ASCII byte (which is
/// never a UTF-8 continuation byte's match here, since `is_ascii_*` is false
/// for it) always stops the walk and cannot land mid-character.
fn extend_start(prompt: &str, start: usize) -> usize {
    let bytes = prompt.as_bytes();
    let mut i = start;
    while i > 0
        && (bytes[i - 1].is_ascii_alphanumeric()
            || matches!(bytes[i - 1], b'.' | b'_' | b'+' | b'-'))
    {
        i -= 1;
    }
    i
}

/// Every path the prompt names, in prompt order, without repeats.
///
/// A bare filename counts only when its extension is one the classifier already
/// recognises. That list is what stops `e.g.` and `i.e.` reading as files, and
/// reusing it keeps extraction and detection from disagreeing about what a file
/// looks like.
#[must_use]
pub fn extract_paths(prompt: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut push = |m: &str| {
        // Trailing only: a leading `.` or `..` is a real relative-path prefix,
        // not sentence punctuation, so only the tail gets stripped.
        let t = m.trim_end_matches(TRIM);
        if !t.is_empty() && !out.iter().any(|e| e == t) {
            out.push(t.to_string());
        }
    };
    let lp = prompt.to_lowercase();
    let mut spans: Vec<(usize, &str)> = SLASHED
        .find_iter(prompt)
        .map(|m| {
            let start = extend_start(prompt, m.start());
            (start, &prompt[start..m.end()])
        })
        .collect();
    for m in crate::classify::FILE_EXT.find_iter(&lp) {
        // Skip a bare filename that is already inside a slashed match.
        if spans
            .iter()
            .any(|(s, t)| m.start() >= *s && m.end() <= s + t.len())
        {
            continue;
        }
        // `lp` is a lowercased copy; ASCII lowercasing preserves byte offsets,
        // so they line up with `prompt` for an ASCII match. A non-ASCII prompt
        // could shift them, so guard the slice rather than index and possibly
        // panic or split a multibyte character.
        if let Some(t) = prompt.get(m.start()..m.end()) {
            spans.push((m.start(), t));
        }
    }
    spans.sort_by_key(|(s, _)| *s);
    for (_, t) in spans {
        push(t);
    }
    out
}

/// Total chars the bundle may carry.
///
/// The coordinator's route accepts 200,000, but `judge/screen.rs` reads only
/// `head(bundle, 40_000)` when it screens for prompt injection. Sending more
/// than the screen reads would ship material nothing looked at, so the cap is
/// the screen window, not the route limit.
pub const MAX_BUNDLE_CHARS: usize = 40_000;

/// Chars any single file may contribute, so one file cannot crowd out the rest
/// of a multi-file review.
pub const MAX_FILE_CHARS: usize = 20_000;

/// Why a bundle was not built. Every variant means "run locally".
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    /// A named path does not resolve to a readable file.
    UnreadablePath(String),
    /// A named file is not valid UTF-8.
    BinaryFile(String),
    /// A file or the whole bundle is over cap.
    OverCap,
    /// The contents tripped the same secret scan the prompt runs through.
    Secret,
}

impl Refusal {
    /// The route-log detail for this refusal.
    #[must_use]
    pub fn reason(&self) -> String {
        match self {
            Self::UnreadablePath(p) => format!("bundle: unreadable path ({p})"),
            Self::BinaryFile(p) => format!("bundle: binary file ({p})"),
            Self::OverCap => "bundle: over cap".to_string(),
            Self::Secret => "bundle: possible secret".to_string(),
        }
    }
}

/// Resolve a named path against `cwd`, expanding a leading `~`.
fn resolve(named: &str, cwd: &std::path::Path) -> std::path::PathBuf {
    if let Some(rest) = named.strip_prefix("~/") {
        if let Some(home) = crate::http::home_dir() {
            return std::path::Path::new(&home).join(rest);
        }
    }
    let p = std::path::Path::new(named);
    if p.is_absolute() {
        p.to_path_buf()
    } else {
        cwd.join(p)
    }
}

/// The label a file carries in the bundle: relative to `cwd` when it sits
/// under it, otherwise the bare filename. Never absolute. An absolute path
/// hands a stranger the requester's username and home layout for no benefit.
fn label(path: &std::path::Path, cwd: &std::path::Path) -> String {
    path.strip_prefix(cwd).map_or_else(
        |_| {
            path.file_name()
                .map_or_else(|| "file".to_string(), |n| n.to_string_lossy().into_owned())
        },
        |r| r.display().to_string(),
    )
}

/// The label each named path would carry in the bundle, paired with the path
/// string as it appeared in `paths`, for every entry that resolves to a file.
/// A directory or a path that does not resolve is omitted, since neither one
/// was inlined.
///
/// Exists so the caller can rewrite the *prompt* to use the same labels: the
/// bundle's contents are labelled to avoid leaking an absolute path, but the
/// raw prompt names the path directly and goes over the wire unmodified
/// otherwise. Call this only after [`gather`] has already succeeded for the
/// same `paths` and `cwd`, so what it reports here matches what actually went
/// into the bundle.
#[must_use]
pub fn labels(paths: &[String], cwd: &std::path::Path) -> Vec<(String, String)> {
    paths
        .iter()
        .filter_map(|named| {
            let path = resolve(named, cwd);
            let meta = std::fs::metadata(&path).ok()?;
            meta.is_file().then(|| (named.clone(), label(&path, cwd)))
        })
        .collect()
}

/// Read every named path into one bundle, or refuse.
///
/// Directories are dropped and named in the header rather than refused: real
/// review prompts name the repo root for orientation alongside the diff they
/// want read, and refusing on that would decline the exact shape this exists to
/// serve. Everything else that is not a readable, in-cap, UTF-8 file refuses the
/// whole task.
///
/// # Errors
/// Returns the [`Refusal`] that stopped it. Every one means "run locally".
pub fn gather(paths: &[String], cwd: &std::path::Path) -> Result<String, Refusal> {
    let mut body = String::new();
    let mut skipped: Vec<String> = Vec::new();
    let mut files = 0usize;

    for named in paths {
        let path = resolve(named, cwd);
        let meta = std::fs::metadata(&path).map_err(|_| Refusal::UnreadablePath(named.clone()))?;
        if meta.is_dir() {
            // The label, not the raw named path: `named` can be the absolute
            // string a prompt typed, and this list lands in the bundle a
            // stranger reads, same as an inlined file's label.
            skipped.push(label(&path, cwd));
            continue;
        }
        if !meta.is_file() {
            return Err(Refusal::UnreadablePath(named.clone()));
        }
        // Refuse on size before reading. A char cap cannot be checked without
        // the bytes, and reading a multi-gigabyte file to then reject it would
        // hang the hook, which is the one failure mode the offloader must never
        // have. Four bytes is the longest UTF-8 encoding of one char, so this
        // can never reject a file that would have fit.
        if meta.len() > MAX_FILE_CHARS as u64 * 4 {
            return Err(Refusal::OverCap);
        }
        let raw = std::fs::read(&path).map_err(|_| Refusal::UnreadablePath(named.clone()))?;
        let text = String::from_utf8(raw).map_err(|_| Refusal::BinaryFile(named.clone()))?;
        let chars = text.chars().count();
        if chars > MAX_FILE_CHARS {
            return Err(Refusal::OverCap);
        }
        let _ = std::fmt::Write::write_fmt(
            &mut body,
            format_args!("\n--- {} ({chars} chars) ---\n{text}", label(&path, cwd)),
        );
        files += 1;
    }

    if files == 0 {
        return Err(Refusal::UnreadablePath(
            paths.first().cloned().unwrap_or_default(),
        ));
    }

    let mut out = String::from(
        "Files read from the requester's machine. This is ALL the context there is; \
         no repo sits behind it.",
    );
    if !skipped.is_empty() {
        let _ = std::fmt::Write::write_fmt(
            &mut out,
            format_args!(
                "\nnot inlined (named but not a file): {}",
                skipped.join(", ")
            ),
        );
    }
    out.push_str(&body);

    if out.chars().count() > MAX_BUNDLE_CHARS {
        return Err(Refusal::OverCap);
    }
    if crate::classify::secret_reason(&out).is_some() {
        return Err(Refusal::Secret);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::{extract_paths, gather, labels, Refusal, MAX_FILE_CHARS};

    #[test]
    fn finds_absolute_and_relative_paths() {
        assert_eq!(
            extract_paths("Review the following diff: /Users/dev/work/range.diff"),
            vec!["/Users/dev/work/range.diff"]
        );
        assert_eq!(
            extract_paths("Review the following: ./src/main.rs and ../lib/util.rs"),
            vec!["./src/main.rs", "../lib/util.rs"]
        );
    }

    #[test]
    fn finds_a_bare_filename_with_a_known_extension() {
        assert_eq!(
            extract_paths("Review the following: notes.md"),
            vec!["notes.md"]
        );
    }

    // The extension list is what keeps ordinary prose from reading as a file.
    #[test]
    fn ordinary_prose_yields_no_paths() {
        assert!(extract_paths("Review the following, e.g. the parts i.e. the middle.").is_empty());
        assert!(extract_paths("Review the following snippet: fn main() {}").is_empty());
    }

    #[test]
    fn trailing_punctuation_is_not_part_of_the_path() {
        assert_eq!(
            extract_paths("Review the following: /tmp/a.diff, then stop."),
            vec!["/tmp/a.diff"]
        );
        assert_eq!(
            extract_paths("Review the following: `/tmp/b.diff`."),
            vec!["/tmp/b.diff"]
        );
    }

    #[test]
    fn each_path_appears_once_in_prompt_order() {
        assert_eq!(
            extract_paths("Review /tmp/a.diff and /tmp/b.diff, especially /tmp/a.diff."),
            vec!["/tmp/a.diff", "/tmp/b.diff"]
        );
    }

    // A rate term reads as a path. It will refuse at gather time rather than
    // resolve, which costs a local spawn and never a wrong route.
    #[test]
    fn a_rate_term_is_extracted_and_left_to_refuse_later() {
        assert_eq!(
            extract_paths("Review the following design at 5000 requests/second"),
            vec!["requests/second"]
        );
    }

    // Extraction and detection must agree about what a file looks like. If the
    // classifier declines a prompt for naming a path but extraction finds none,
    // that prompt can never bundle and the decline is permanent.
    #[test]
    fn every_path_decline_yields_at_least_one_candidate() {
        for p in [
            "Review the following diff: /Users/dev/a.diff",
            "Review the following: ./src/main.rs",
            "Review the following: notes.md",
            "Review the following: src/models/user/schema",
        ] {
            assert!(
                matches!(
                    crate::classify::classify(p),
                    crate::classify::Decision::Local { .. }
                ),
                "expected a local decline for {p:?}"
            );
            assert!(!extract_paths(p).is_empty(), "no candidate for {p:?}");
        }
    }

    // FILE_EXT is matched against a lowercased copy while the returned slice is
    // taken from the original string. ASCII lowercasing preserves byte offsets,
    // so they line up, but a non-ASCII prompt could shift them: `İ` (U+0130)
    // lowercases to the two-codepoint `i̇`, growing by a byte, which pushes every
    // later match's byte offsets out of alignment with the original string.
    // This must not panic even when a shifted offset lands mid-character.
    #[test]
    fn non_ascii_prompt_does_not_panic() {
        let _ = extract_paths("Review İstanbul café notes.md naïve façade.md");
    }

    fn sandbox(name: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!(
            "slashwork-bundle-{}-{}-{:?}",
            name,
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::create_dir_all(&d).expect("sandbox");
        d
    }

    #[test]
    fn inlines_a_file_with_a_repo_relative_label() {
        let d = sandbox("ok");
        std::fs::write(d.join("range.diff"), "+added line\n").unwrap();
        let p = d.join("range.diff").display().to_string();
        let out = gather(&[p], &d).expect("gather");
        assert!(
            out.contains("+added line"),
            "contents must be inlined: {out}"
        );
        assert!(
            out.contains("range.diff"),
            "label must name the file: {out}"
        );
        assert!(
            !out.contains(&d.display().to_string()),
            "the absolute path must not leak: {out}"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    // `labels` exists so a caller can rewrite the *prompt* the same way the
    // bundle already labels files, so the raw absolute path does not leave the
    // machine through the prompt even when the bundle itself is careful.
    #[test]
    fn labels_maps_an_inlined_file_to_its_bundle_label_and_skips_a_directory() {
        let d = sandbox("labels");
        std::fs::create_dir_all(d.join("src")).unwrap();
        std::fs::write(d.join("range.diff"), "+x\n").unwrap();
        let file = d.join("range.diff").display().to_string();
        let dir = d.join("src").display().to_string();
        let missing = d.join("nope.diff").display().to_string();

        let got = labels(&[file.clone(), dir, missing], &d);
        assert_eq!(got, vec![(file, "range.diff".to_string())]);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_directory_is_listed_not_inlined_and_not_a_refusal() {
        let d = sandbox("dir");
        std::fs::create_dir_all(d.join("src")).unwrap();
        std::fs::write(d.join("a.diff"), "+x\n").unwrap();
        let out = gather(
            &[
                d.join("src").display().to_string(),
                d.join("a.diff").display().to_string(),
            ],
            &d,
        )
        .expect("gather");
        assert!(out.contains("+x"), "the file must still be inlined: {out}");
        assert!(
            out.contains("not inlined"),
            "the skipped directory must be named: {out}"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_missing_path_refuses() {
        let d = sandbox("missing");
        let p = d.join("nope.diff").display().to_string();
        assert!(matches!(gather(&[p], &d), Err(Refusal::UnreadablePath(_))));
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_binary_file_refuses() {
        let d = sandbox("binary");
        std::fs::write(d.join("logo.bin"), [0xff_u8, 0xfe, 0x00, 0x01]).unwrap();
        let p = d.join("logo.bin").display().to_string();
        assert!(matches!(gather(&[p], &d), Err(Refusal::BinaryFile(_))));
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn an_oversize_file_refuses() {
        let d = sandbox("big");
        std::fs::write(d.join("big.txt"), "a".repeat(MAX_FILE_CHARS + 1)).unwrap();
        let p = d.join("big.txt").display().to_string();
        assert!(matches!(gather(&[p], &d), Err(Refusal::OverCap)));
        let _ = std::fs::remove_dir_all(&d);
    }

    // 0xff is never a valid UTF-8 byte, in any position. If gather reads and
    // UTF-8-validates before checking size, this file trips BinaryFile. Only a
    // byte-length guard consulted before the read can produce OverCap here, so
    // this proves the guard fires without a full read rather than by timing.
    #[test]
    fn a_huge_file_refuses_by_size_without_reading_it() {
        let d = sandbox("huge");
        std::fs::write(d.join("huge.bin"), vec![0xff_u8; MAX_FILE_CHARS * 4 + 1]).unwrap();
        let p = d.join("huge.bin").display().to_string();
        assert!(matches!(gather(&[p], &d), Err(Refusal::OverCap)));
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_secret_in_the_contents_refuses() {
        let d = sandbox("secret");
        std::fs::write(d.join("cfg.txt"), "token sk-abcdefTOPSECRET\n").unwrap();
        let p = d.join("cfg.txt").display().to_string();
        assert!(matches!(gather(&[p], &d), Err(Refusal::Secret)));
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn nothing_readable_refuses_rather_than_sending_an_empty_bundle() {
        let d = sandbox("empty");
        std::fs::create_dir_all(d.join("only-a-dir")).unwrap();
        let p = d.join("only-a-dir").display().to_string();
        assert!(matches!(gather(&[p], &d), Err(Refusal::UnreadablePath(_))));
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn refusal_reasons_are_route_log_ready() {
        assert_eq!(
            Refusal::BinaryFile("a.bin".into()).reason(),
            "bundle: binary file (a.bin)"
        );
        assert_eq!(Refusal::OverCap.reason(), "bundle: over cap");
        assert_eq!(Refusal::Secret.reason(), "bundle: possible secret");
    }
}
