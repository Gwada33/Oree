//! Thin bridge between Swift and `adblock-rust`, exposed through UniFFI.
//!
//! Two jobs:
//!  1. turn ABP/uBO filter lists into WebKit content-rule-list JSON, split into
//!     chunks small enough for `WKContentRuleListStore` (which caps a single
//!     list at 150 000 rules);
//!  2. answer "which elements should be hidden on this page?" for cosmetic
//!     filtering, which WebKit's native rule lists express poorly.

use adblock::content_blocking::{CbRule, CbType};
use adblock::lists::{FilterSet, ParseOptions};
use adblock::Engine;
use std::sync::{Arc, Mutex};

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum BridgeError {
    #[error("the filter lists could not be converted to content-blocking rules")]
    ConversionFailed,
    #[error("serializing rules failed: {0}")]
    Serialization(String),
    #[error("{exceptions} exception rules cannot fit in chunks of {cap} rules")]
    ChunkCapTooSmall { exceptions: u32, cap: u32 },
}

fn is_exception(rule: &CbRule) -> bool {
    matches!(rule.action.typ, CbType::IgnorePreviousRules)
}

/// Converts filter-list texts into one or more WebKit content-rule-list JSON
/// documents of at most `max_rules_per_chunk` rules each.
///
/// Each WebKit rule list is evaluated independently, so an
/// `ignore-previous-rules` exception only cancels blocking rules in *its own*
/// list. To keep exceptions effective after splitting, every chunk carries the
/// full set of exceptions after its share of blocking rules.
#[uniffi::export]
pub fn convert_to_content_blocking(
    list_texts: Vec<String>,
    max_rules_per_chunk: u32,
) -> Result<Vec<String>, BridgeError> {
    let mut set = FilterSet::new(true);
    for text in list_texts {
        set.add_filter_list(text, ParseOptions::default());
    }
    let (rules, _filters_used) = set
        .into_content_blocking()
        .map_err(|_| BridgeError::ConversionFailed)?;

    let (exceptions, blockers): (Vec<CbRule>, Vec<CbRule>) =
        rules.into_iter().partition(is_exception);

    let cap = max_rules_per_chunk as usize;
    if exceptions.len() >= cap {
        return Err(BridgeError::ChunkCapTooSmall {
            exceptions: exceptions.len() as u32,
            cap: max_rules_per_chunk,
        });
    }
    let blockers_per_chunk = cap - exceptions.len();

    let mut chunks = Vec::new();
    if blockers.is_empty() {
        return Ok(chunks);
    }
    for slice in blockers.chunks(blockers_per_chunk) {
        let mut chunk: Vec<&CbRule> = slice.iter().collect();
        chunk.extend(exceptions.iter());
        let json = serde_json::to_string(&chunk)
            .map_err(|e| BridgeError::Serialization(e.to_string()))?;
        chunks.push(json);
    }
    Ok(chunks)
}

/// Cosmetic-filter engine, built once from the same lists and queried per page.
#[derive(uniffi::Object)]
pub struct CosmeticEngine {
    engine: Mutex<Engine>,
}

#[uniffi::export]
impl CosmeticEngine {
    #[uniffi::constructor]
    pub fn new(list_texts: Vec<String>) -> Arc<Self> {
        let mut set = FilterSet::new(false);
        for text in list_texts {
            set.add_filter_list(text, ParseOptions::default());
        }
        Arc::new(Self {
            engine: Mutex::new(Engine::new_with_filter_set(set)),
        })
    }

    /// CSS hiding the page's ad elements. One rule per selector so a single
    /// selector the browser can't parse doesn't discard all the others.
    pub fn css_for_url(&self, url: String) -> String {
        let resources = self.engine.lock().unwrap().url_cosmetic_resources(&url);
        let mut selectors: Vec<&String> = resources.hide_selectors.iter().collect();
        selectors.sort();
        selectors
            .into_iter()
            .map(|s| format!("{s}{{display:none!important}}"))
            .collect::<Vec<_>>()
            .join("\n")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIST: &str = "||ads.example.com^\n||tracker.example.net^$third-party\n@@||ads.example.com/allowed^\nexample.org##.banner\n";

    #[test]
    fn converts_a_small_list() {
        let chunks = convert_to_content_blocking(vec![LIST.to_string()], 1000).unwrap();
        assert_eq!(chunks.len(), 1);
        let parsed: Vec<serde_json::Value> = serde_json::from_str(&chunks[0]).unwrap();
        assert!(parsed.iter().any(|r| r["trigger"]["url-filter"].as_str().unwrap_or("").contains("ads")));
    }

    #[test]
    fn splitting_keeps_exceptions_in_every_chunk() {
        let mut list = String::new();
        for i in 0..40 {
            list.push_str(&format!("||ad{i}.example.com^\n"));
        }
        list.push_str("@@||ad1.example.com/ok^\n");
        let chunks = convert_to_content_blocking(vec![list], 10).unwrap();
        assert!(chunks.len() > 1, "40 blocking rules must not fit in chunks of 10");
        for chunk in &chunks {
            let parsed: Vec<serde_json::Value> = serde_json::from_str(chunk).unwrap();
            assert!(parsed.len() <= 10);
            assert!(parsed.iter().any(|r| r["action"]["type"] == "ignore-previous-rules"));
        }
    }

    #[test]
    fn cosmetic_engine_hides_site_specific_selectors() {
        let engine = CosmeticEngine::new(vec![LIST.to_string()]);
        assert!(engine.css_for_url("https://example.org/page".into()).contains(".banner"));
        assert!(!engine.css_for_url("https://other.net/".into()).contains(".banner"));
    }
}
