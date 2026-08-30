//! Pure routing classifier for the slashwork offload core.
//!
//! A faithful Rust port of the decision logic in the Claude Code
//! `plugins/work/hooks/intercept.sh` hook, so every harness adapter shares one
//! tested implementation instead of three that drift. Given a subagent prompt,
//! decide whether it is confidently self-contained and route it to exactly one
//! task class, or fall through to a local spawn with a reason.
//!
//! Conservative by construction: a missed routable spawn costs nothing, a
//! misrouted local spawn ships local work to a stranger and replaces the real
//! answer, so every ambiguous or local-smelling prompt declines. No I/O here;
//! the caller (`route`) owns the token, base URL, and network.
//!
//! The checks and their order mirror `intercept.sh` exactly. The bash hook runs
//! its greps line by line; this port searches the whole prompt at once. That is
//! equivalent for these patterns: the only line anchor is the local-path `^`,
//! and a path at the start of a later line is still preceded by a newline, which
//! the alternative `[^a-z]` branch matches. Every other check is `\b`-anchored
//! or a bare substring, both position-based and line-independent.

use regex::Regex;
use std::sync::LazyLock;

/// The routable task classes. The lowercase `as_str` values are the public API
/// contract the coordinator expects (they match `economy::TaskClass` there).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Class {
    Research,
    Prose,
    Codegen,
    Review,
}

impl Class {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Research => "research",
            Self::Prose => "prose",
            Self::Codegen => "codegen",
            Self::Review => "review",
        }
    }
}

/// The classifier's verdict for one prompt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    /// Not routable: fall through to a local spawn. `reason` feeds the route log
    /// and stderr, mirroring `intercept.sh`'s `decline`.
    Local { reason: String },
    /// Confidently self-contained and matched exactly one class: route it.
    Routable { class: Class },
}

/// Largest prompt (bytes) that is routable. v1 inlines no files, so the prompt
/// is the whole payload and an over-cap prompt cannot be routed. ~64KB.
pub const BUNDLE_CAP_BYTES: usize = 65536;

// Compile each pattern once. The patterns are static and covered by the tests
// below, so an `unwrap` here can only fail if a test would already fail.

/// Anything reaching into this machine or repo: absolute path roots, `~/`,
/// `./`, `../`, or a Windows `c:\` drive. Broad on purpose.
static LOCAL_PATH: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(^|[^a-z])(/(users|home|var|etc|tmp|opt|usr|private|volumes|mnt|srv|root|library)/|~/|\./|\.\./|[a-z]:\\)",
    )
    .unwrap()
});

/// A bare filename with a known extension (`report.csv`, `api.h`). Requiring a
/// known extension keeps ordinary prose (`i.e.`, `e.g.`) from reading as files.
static FILE_EXT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"\b[a-z0-9_-]+\.(csv|tsv|txt|md|rst|json|ya?ml|toml|ini|conf|cfg|env|xml|html?|css|scss|sass|less|sql|log|lock|pdf|png|jpe?g|gif|svg|webp|ico|ipynb|rs|py|js|mjs|ts|jsx|tsx|go|java|rb|php|cpp|hpp|cc|cxx|hh|cs|swift|kt|scala|clj|hs|dart|sh|bash|zsh|ps1|bat|db|sqlite|parquet|avro|proto|graphql|gz|tgz|zip|tar|xlsx|xls|docx|doc|pptx|ppt|npy|h5|pkl|wav|mp3|mp4|mov|webm|c|h)\b",
    )
    .unwrap()
});

/// A deep relative path (`src/models/user`, 2+ separators). A single slash is a
/// rate term (`requests/second`) and must not decline.
static DEEP_PATH: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\b[a-z0-9_-]+/[a-z0-9_-]+/[a-z0-9_./-]+").unwrap());

/// Repo and build verbs that only make sense against the local tree.
static REPO_VERBS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"\b(git|commit|repo|repository|codebase|the tests?|test suite|run the|npm |cargo |pytest|build the|compile|refactor|edit the|modify the|this file|these files|the file|attached|working directory|cwd|localhost)\b",
    )
    .unwrap()
});

/// Words that fence a subagent off from this machine. A repo-vocabulary match
/// inside a clause carrying one of these is the prompt saying what NOT to touch,
/// which argues the task is self-contained rather than local.
static NEGATION: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\b(do not|don't|dont|never|without|no need to|avoid|refrain from)\b").unwrap()
});

/// `don't forget to run the tests` asks for the tests. The negation belongs to
/// the verb of forgetting, not to the operation, so it is not a fence.
static FALSE_FENCE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\W*(forget|fail|hesitate|neglect)\b").unwrap());

/// Credential key families and a broad high-entropy blob. Run against the raw
/// (case-preserving) prompt so `AKIA`, `AIza`, and `-----BEGIN` still match.
///
/// The `sk-` families require a run of at least 20 characters after the prefix.
/// A one-character lookahead matched any hyphen-then-alphanumeric word, so
/// ordinary filenames (`task-1-brief.md`, carrying `sk-1`) read as credentials
/// and declined the bundles that name them. A real key runs to 48 characters
/// and the legacy form is caught twice over by the trailing high-entropy blob.
static SECRET_KEYS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(sk-[A-Za-z0-9]{20,}|sk-(proj|svcacct|admin)-[A-Za-z0-9_-]{20,}|sk_(live|test)_|rk_live_|ghp_[A-Za-z0-9]|gho_[A-Za-z0-9]|github_pat_|glpat-|AKIA[0-9A-Z]{12}|AIza[0-9A-Za-z_-]{20,}|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}|-----BEGIN|xox[baprs]-|SLASHWORK_TOKEN|[A-Za-z0-9+/]{40,}={0,2})",
    )
    .unwrap()
});

/// Prose cues for a secret, plus decode requests that could smuggle one. Run
/// against the lowercased prompt.
static SECRET_WORDS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(api[_ -]?key|access[_ -]?token|secret[_ -]?key|bearer |password|passphrase|credential|\.env\b|private key|base64|b64decode|decode this)",
    )
    .unwrap()
});

/// The four class signatures, in the same order `intercept.sh` tests them (the
/// first match names the class; more than one match declines).
static RESEARCH: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"\b(research|compare|survey|find prior art|investigate the options|state of the art|literature review|pros and cons of)\b",
    )
    .unwrap()
});
static REVIEW: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"\b(review|critique|assess|evaluate|analyze) (this|the following|the below|the diff|the log|the snippet)\b",
    )
    .unwrap()
});
static PROSE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"\b(write|draft|compose|summarize|summarise) (a|an|the) (report|summary|blog|article|email|post|essay|readme|documentation|release note|explanation)\b",
    )
    .unwrap()
});
static CODEGEN: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"\b(write|implement|generate) (a|an) (function|script|regex|regular expression|sql query|class|module|algorithm|parser)\b",
    )
    .unwrap()
});

/// True when the clause fences the machine off rather than reaching into it.
fn is_fenced(clause: &str) -> bool {
    NEGATION
        .find_iter(clause)
        .any(|m| !FALSE_FENCE.is_match(&clause[m.end()..]))
}

/// True when any clause uses the repo vocabulary without a fence around it.
///
/// Clause-scoped on purpose: one fenced mention does not excuse the rest of the
/// prompt, so "do not read local files, but run the tests" still declines on its
/// second clause. Only the repo verbs get this treatment; a literal path or a
/// real filename stays absolute evidence, fenced or not.
fn has_unfenced_repo_verb(prompt: &str) -> bool {
    prompt
        .split(['.', ';', ',', '\n'])
        .any(|clause| REPO_VERBS.is_match(clause) && !is_fenced(clause))
}

/// Local-context signals (step 3 of the pipeline): a path, a real file, or a
/// repo/build verb. `lp` is the lowercased prompt.
pub(crate) fn local_context_reason(lp: &str) -> Option<String> {
    if LOCAL_PATH.is_match(lp) {
        return Some("local path reference".to_string());
    }
    if FILE_EXT.is_match(lp) || DEEP_PATH.is_match(lp) {
        return Some("probable local file or path".to_string());
    }
    if has_unfenced_repo_verb(lp) {
        return Some("local/repo operation".to_string());
    }
    None
}

/// The full secret scan (step 4): key families against the raw text, prose
/// cues against the lowercased copy.
pub(crate) fn secret_reason(raw: &str, lp: &str) -> Option<String> {
    if SECRET_KEYS.is_match(raw) {
        return Some("possible secret or high-entropy blob in prompt".to_string());
    }
    if SECRET_WORDS.is_match(lp) {
        return Some("possible secret in prompt".to_string());
    }
    None
}

/// The high-precision half of the secret scan, for callers vetting material
/// other than the prompt (the review bundle): key families and high-entropy
/// blobs only, never the prose vocabulary, which code legitimately uses
/// ("password" in an auth module is not a leak).
#[must_use]
pub fn secret_key_reason(text: &str) -> Option<&'static str> {
    SECRET_KEYS.is_match(text).then_some("secret-shaped token")
}

/// Classify a subagent prompt into a routing decision. See the module docs for
/// the invariant: unsure means local.
#[must_use]
pub fn classify(prompt: &str) -> Decision {
    let local = |reason: &str| Decision::Local {
        reason: reason.to_string(),
    };

    // 1. Self-exemption: our own earning worker's spawns carry a "task_id:"
    //    marker (submit keys on the same one). Never route them, or the
    //    interceptor would repost its own work forever.
    if prompt.contains("task_id:") {
        return local("self-worker task");
    }

    // 2. Bundle cap: the prompt is the whole payload in v1.
    let bytes = prompt.len();
    if bytes > BUNDLE_CAP_BYTES {
        return Decision::Local {
            reason: format!("prompt over 64KB ({bytes})"),
        };
    }

    // Lowercased copy for every case-insensitive check.
    let lp = prompt.to_lowercase();

    // 3. Local-context signals: a path, a real file, or a repo/build verb means
    //    the task reaches into this machine and cannot run on a stranger's box.
    if let Some(reason) = local_context_reason(&lp) {
        return Decision::Local { reason };
    }

    // 4. Secret scan: never send credentials off the machine. Key families run
    //    against the raw prompt; the prose cues against the lowercased copy.
    if let Some(reason) = secret_reason(prompt, &lp) {
        return Decision::Local { reason };
    }

    // 5. Class by high-confidence signature. Require exactly one match so an
    //    ambiguous prompt declines rather than guessing a price.
    let mut class = None;
    let mut matches = 0u32;
    for (re, c) in [
        (&*RESEARCH, Class::Research),
        (&*REVIEW, Class::Review),
        (&*PROSE, Class::Prose),
        (&*CODEGEN, Class::Codegen),
    ] {
        if re.is_match(&lp) {
            matches += 1;
            if class.is_none() {
                class = Some(c);
            }
        }
    }

    match (matches, class) {
        (1, Some(c)) => Decision::Routable { class: c },
        _ => Decision::Local {
            reason: format!("no single confident class (matched {matches})"),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::{classify, secret_key_reason, Class, Decision, BUNDLE_CAP_BYTES};

    // Assert a prompt routes to a specific class.
    fn assert_routes(prompt: &str, class: Class) {
        match classify(prompt) {
            Decision::Routable { class: got } => assert_eq!(got, class, "prompt: {prompt:?}"),
            Decision::Local { reason } => {
                panic!("expected {class:?}, got local ({reason}) for {prompt:?}")
            }
        }
    }

    // Assert a prompt declines to a local spawn.
    fn assert_local(prompt: &str) {
        match classify(prompt) {
            Decision::Local { .. } => {}
            Decision::Routable { class } => {
                panic!("expected local, got {class:?} for {prompt:?}")
            }
        }
    }

    // --- Routable classes (intercept_test.sh scenarios 1, 2, and class shapes) ---

    #[test]
    fn research_routes() {
        assert_routes(
            "Research and compare the leading approaches to rate limiting; give pros and cons of each.",
            Class::Research,
        );
    }

    #[test]
    fn prose_routes() {
        assert_routes(
            "Draft a report summarizing the quarterly numbers below: revenue up, costs flat.",
            Class::Prose,
        );
    }

    #[test]
    fn codegen_routes() {
        assert_routes(
            "Write a regular expression that validates an IPv4 address.",
            Class::Codegen,
        );
    }

    #[test]
    fn review_routes() {
        assert_routes(
            "Review the following algorithm and note any correctness issues.",
            Class::Review,
        );
    }

    // --- Self-exemption (scenario 4) ---

    #[test]
    fn self_worker_declines() {
        assert_local("task_id: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\nRead the job and solve it.");
    }

    // A prompt that would otherwise route still exempts if it carries the marker.
    #[test]
    fn self_worker_marker_wins_over_a_routable_prompt() {
        match classify("task_id: 123\nResearch and compare the options; pros and cons of each.") {
            Decision::Local { reason } => assert_eq!(reason, "self-worker task"),
            other @ Decision::Routable { .. } => panic!("marker must exempt: {other:?}"),
        }
    }

    // --- Bundle cap ---

    #[test]
    fn over_cap_prompt_declines() {
        let big = "a".repeat(BUNDLE_CAP_BYTES + 1);
        match classify(&big) {
            Decision::Local { reason } => assert!(reason.starts_with("prompt over 64KB")),
            other @ Decision::Routable { .. } => panic!("over-cap must decline: {other:?}"),
        }
    }

    #[test]
    fn at_cap_is_not_rejected_for_size() {
        // Exactly the cap is allowed through the size gate (it then declines for
        // want of a class, not for size).
        let at = "a".repeat(BUNDLE_CAP_BYTES);
        match classify(&at) {
            Decision::Local { reason } => assert!(
                !reason.contains("over 64KB"),
                "at cap should not fail the size gate: {reason}"
            ),
            other @ Decision::Routable { .. } => {
                panic!("a class-less blob should be local: {other:?}")
            }
        }
    }

    // --- Local paths and files (scenarios 5, 10, 19b) ---

    #[test]
    fn local_path_declines() {
        assert_local("Refactor the function in ./src/main.rs and run the tests.");
    }

    #[test]
    fn broadened_paths_and_extensions_decline() {
        assert_local("Summarize the findings in q3-results.csv");
        assert_local("Review the following errors in /var/log/app.log");
        assert_local("Implement a function matching the interface in api.h");
        assert_local("Review the dataset in src/data.csv");
    }

    #[test]
    fn deep_paths_and_real_files_decline() {
        assert_local("Research and compare the schemas defined in src/models/user/schema; give pros and cons.");
        assert_local("Research and compare the numbers captured in benchmark.csv; give the pros and cons of each.");
        assert_local("Research and compare the interfaces declared in api.h; give the pros and cons of each.");
    }

    // --- Negated local context ---
    //
    // A careful prompt writer fences a subagent off from the machine ("do not
    // read any local files"). Matching the repo vocabulary inside that fence
    // read the fence itself as evidence of local work, so the more carefully a
    // prompt was written, the more likely it declined. Only the repo verbs are
    // negation-aware: a literal path or filename is concrete enough to keep
    // declining on, negated or not.

    #[test]
    fn a_negated_repo_mention_still_routes() {
        assert_routes(
            "Research and compare the leading rate-limiting approaches; give the pros and cons of each. Do not read any local files, do not run any commands, do not reference this repository.",
            Class::Research,
        );
    }

    #[test]
    fn a_real_repo_operation_still_declines() {
        assert_local("Research and compare our options, then run the tests and commit the result.");
    }

    #[test]
    fn one_real_repo_clause_outweighs_a_negated_one() {
        assert_local(
            "Research and compare the options; do not read any local files, but run the tests when you are done.",
        );
    }

    #[test]
    fn dont_forget_is_an_instruction_not_a_fence() {
        // "don't forget to X" asks for X. Reading it as a negation would route a
        // prompt whose actual instruction is a local operation.
        assert_local("Research and compare the options; don't forget to run the tests afterwards.");
    }

    #[test]
    fn a_negated_literal_path_still_declines() {
        // Paths stay absolute evidence: the prompt named a real location on this
        // machine, and the conservative rule holds regardless of the verb.
        assert_local(
            "Research and compare the options; do not read /Users/mvolz/notes.txt while you work.",
        );
    }

    // --- Secrets (scenarios 6, 11) ---

    #[test]
    fn secret_key_declines() {
        assert_local(
            "Write a script that authenticates with api_key sk-abcdefTOPSECRET and fetches data.",
        );
    }

    #[test]
    fn broadened_secret_families_decline() {
        assert_local("Write a function that charges a card with key sk_live_51abcdEFGHijklMNOP");
        assert_local("Implement a script using github_pat_11ABCDEFG0abcdefghij");
        assert_local(
            "Write a function that calls the API with AIzaSyD-abcdefghijklmnopqrstuvwxyz012",
        );
    }

    #[test]
    fn ordinary_hyphen_digit_words_are_not_secret_shaped() {
        // A task-numbered filename carries the literal substring "sk-1", which
        // is not a key: a real one runs on for tens of characters. Bundled
        // reviews name these files, so a match here declines the whole bundle.
        for text in [
            "=== file: task-1-brief.md ===",
            "review task-14-brief.md against task-2-report.md",
            "the disk-2 volume and the risk-3 register",
        ] {
            assert_eq!(secret_key_reason(text), None, "false positive on: {text}");
        }
    }

    #[test]
    fn real_openai_keys_are_still_secret_shaped() {
        for text in [
            "sk-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUV",
            "sk-proj-abcdefghijklmnopqrstuvwxyz0123456789",
            "sk-svcacct-abcdefghijklmnopqrstuvwxyz0123456789",
        ] {
            assert!(secret_key_reason(text).is_some(), "missed key: {text}");
        }
    }

    // --- Ambiguity (scenario 7) ---

    #[test]
    fn no_confident_class_declines() {
        match classify("Do the needful with the thing.") {
            Decision::Local { reason } => assert!(reason.contains("no single confident class")),
            other @ Decision::Routable { .. } => panic!("unclassifiable must decline: {other:?}"),
        }
    }

    #[test]
    fn two_classes_decline() {
        // Both a research signature and a prose signature present: ambiguous, so
        // decline rather than guess which price to charge.
        match classify("Research the topic, then write a report summarizing it.") {
            Decision::Local { reason } => assert!(reason.contains("matched 2")),
            other @ Decision::Routable { .. } => panic!("two-class prompt must decline: {other:?}"),
        }
    }

    // --- Prose punctuation and rate terms route (scenario 19) ---

    #[test]
    fn prose_punctuation_and_rate_terms_route() {
        assert_routes(
            "Research and compare rate limiting algorithms, e.g. token bucket and leaky bucket; give the pros and cons of each.",
            Class::Research,
        );
        assert_routes(
            "Research the leading caching strategies, i.e. write-through and write-back, and compare the pros and cons of each.",
            Class::Research,
        );
        assert_routes(
            "Research and compare API gateway designs that sustain 5000 requests/second; give the pros and cons of each.",
            Class::Research,
        );
    }

    // --- Class-name matches the coordinator contract ---

    #[test]
    fn class_strings_are_the_api_contract() {
        assert_eq!(Class::Research.as_str(), "research");
        assert_eq!(Class::Prose.as_str(), "prose");
        assert_eq!(Class::Codegen.as_str(), "codegen");
        assert_eq!(Class::Review.as_str(), "review");
    }
}
