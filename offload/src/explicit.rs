//! Explicit offload spawns: the `slashwork-work:offload` agent.
//!
//! The implicit path (classify every subagent spawn, route the confident ones)
//! is conservative by design and misses everything phrased loosely. The
//! offload agent flips the contract: the model addresses the network on
//! purpose, names the class itself in a `class:` header line, and writes the
//! prompt to be self-contained because the agent's own description says so.
//!
//! What stays non-negotiable is the safety half of the classifier. An explicit
//! spawn still declines, visibly, on anything that reaches into the machine or
//! looks secret-bearing; only the trigger-phrase strictness (exactly one class
//! signature) is waived, because the header names the class instead.

use crate::classify::{local_context_reason, secret_reason, Class, Decision};

/// The `subagent_type` values that mark a spawn as an explicit offload.
/// Claude Code namespaces plugin agents as `<plugin>:<agent>`.
pub const OFFLOAD_AGENT_TYPES: &[&str] = &["slashwork-work:offload", "offload"];

/// Whether a spawn's `subagent_type` addresses the offload agent.
#[must_use]
pub fn is_offload_agent(subagent_type: Option<&str>) -> bool {
    subagent_type.is_some_and(|t| OFFLOAD_AGENT_TYPES.contains(&t))
}

/// Parse the `class: <name>` header line an explicit prompt opens with.
/// Returns the class and the prompt without the header. Whitespace and case
/// are forgiven; a missing or unknown class is `None`.
#[must_use]
pub fn parse_class_header(prompt: &str) -> Option<(Class, String)> {
    let trimmed = prompt.trim_start();
    let rest = trimmed.strip_prefix("class:")?;
    let (line, body) = rest.split_once('\n').unwrap_or((rest, ""));
    let class = match line.trim().to_lowercase().as_str() {
        "research" => Class::Research,
        "prose" => Class::Prose,
        "codegen" => Class::Codegen,
        "review" => Class::Review,
        _ => return None,
    };
    Some((class, body.trim_start().to_string()))
}

/// Classify an explicit offload prompt. The class comes from the header; the
/// machine-reach and secret checks still apply to the body and decline exactly
/// as the implicit path would.
#[must_use]
pub fn classify_explicit(prompt: &str) -> Decision {
    let Some((class, body)) = parse_class_header(prompt) else {
        return Decision::Local {
            reason:
                "offload agent prompt has no class: header (research, prose, codegen, or review)"
                    .to_string(),
        };
    };
    if body.trim().is_empty() {
        return Decision::Local {
            reason: "offload agent prompt has no work order after the class: header".to_string(),
        };
    }
    if body.len() > crate::classify::BUNDLE_CAP_BYTES {
        return Decision::Local {
            reason: format!("prompt over 64KB ({})", body.len()),
        };
    }
    let lp = body.to_lowercase();
    if let Some(reason) = local_context_reason(&lp) {
        return Decision::Local { reason };
    }
    if let Some(reason) = secret_reason(&body, &lp) {
        return Decision::Local { reason };
    }
    Decision::Routable { class }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_plugin_namespaced_agent_type_is_recognised() {
        assert!(is_offload_agent(Some("slashwork-work:offload")));
        assert!(is_offload_agent(Some("offload")));
        assert!(!is_offload_agent(Some("general-purpose")));
        assert!(!is_offload_agent(None));
    }

    #[test]
    fn the_header_names_the_class_and_is_stripped() {
        let (class, body) =
            parse_class_header("class: research\nCompare the three big caching strategies.")
                .expect("parses");
        assert_eq!(class, Class::Research);
        assert_eq!(body, "Compare the three big caching strategies.");
    }

    #[test]
    fn header_case_and_whitespace_are_forgiven() {
        let (class, _) =
            parse_class_header("  class:  PROSE\nWrite about caching.").expect("parses");
        assert_eq!(class, Class::Prose);
    }

    #[test]
    fn a_loosely_phrased_prompt_routes_with_a_header() {
        // The implicit classifier declines this (no confident signature); the
        // header supplies the class, so it routes.
        let d = classify_explicit(
            "class: research\nWhat are the tradeoffs between the common approaches to database connection pooling, and when does each win?",
        );
        assert_eq!(
            d,
            Decision::Routable {
                class: Class::Research
            }
        );
    }

    #[test]
    fn a_missing_header_declines_with_a_teachable_reason() {
        match classify_explicit("Compare the common connection pooling approaches.") {
            Decision::Local { reason } => assert!(reason.contains("class: header"), "{reason}"),
            other @ Decision::Routable { .. } => panic!("must decline: {other:?}"),
        }
    }

    #[test]
    fn a_header_with_no_body_declines() {
        match classify_explicit("class: research\n   ") {
            Decision::Local { reason } => assert!(reason.contains("work order"), "{reason}"),
            other @ Decision::Routable { .. } => panic!("must decline: {other:?}"),
        }
    }

    #[test]
    fn a_path_still_declines_an_explicit_prompt() {
        match classify_explicit("class: review\nReview the code in /Users/me/project/src for bugs.")
        {
            Decision::Local { reason } => assert!(reason.contains("path"), "{reason}"),
            other @ Decision::Routable { .. } => panic!("must decline: {other:?}"),
        }
    }

    #[test]
    fn a_repo_verb_still_declines_an_explicit_prompt() {
        match classify_explicit("class: codegen\nWrite a function and run the tests in the repo.") {
            Decision::Local { reason } => assert!(reason.contains("local/repo"), "{reason}"),
            other @ Decision::Routable { .. } => panic!("must decline: {other:?}"),
        }
    }

    #[test]
    fn a_secret_still_declines_an_explicit_prompt() {
        match classify_explicit("class: prose\nWrite a summary; the api key is sk-abc123def456.") {
            Decision::Local { reason } => assert!(reason.contains("secret"), "{reason}"),
            other @ Decision::Routable { .. } => panic!("must decline: {other:?}"),
        }
    }

    #[test]
    fn two_signatures_do_not_decline_an_explicit_prompt() {
        // "research ... write a summary" declines implicitly (two classes); the
        // header settles it explicitly.
        let d = classify_explicit(
            "class: prose\nResearch the history of the metric system briefly, then write a summary of it for a newsletter.",
        );
        assert_eq!(
            d,
            Decision::Routable {
                class: Class::Prose
            }
        );
    }
}
