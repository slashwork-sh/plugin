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

#[cfg(test)]
mod tests {
    use super::extract_paths;

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
}
