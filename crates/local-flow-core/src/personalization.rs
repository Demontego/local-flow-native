//! Local-only dictionary, snippets, and per-app writing profiles.

use crate::context::DictationContext;
use crate::error::{Error, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct Replacement {
    pub heard: String,
    pub replace_with: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct Snippet {
    pub trigger: String,
    pub expansion: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Personalization {
    #[serde(default)]
    pub dictionary: Vec<Replacement>,
    #[serde(default)]
    pub snippets: Vec<Snippet>,
    #[serde(default)]
    pub app_styles: BTreeMap<String, String>,
    #[serde(default = "default_true")]
    pub cleanup_enabled: bool,
}

impl Default for Personalization {
    fn default() -> Self {
        Self {
            dictionary: Vec::new(),
            snippets: Vec::new(),
            app_styles: BTreeMap::new(),
            cleanup_enabled: true,
        }
    }
}

fn default_true() -> bool {
    true
}

pub fn path(cache: &Path) -> PathBuf {
    cache.join("personalization.json")
}

pub fn load(cache: &Path) -> Personalization {
    let Ok(data) = fs::read_to_string(path(cache)) else {
        return Personalization::default();
    };
    serde_json::from_str(&data).unwrap_or_default()
}

pub fn save(cache: &Path, settings: &Personalization) -> Result<()> {
    fs::create_dir_all(cache)?;
    let json = serde_json::to_string_pretty(settings).map_err(|e| Error::msg(e.to_string()))?;
    fs::write(path(cache), json)?;
    Ok(())
}

pub fn apply_context(ctx: &mut DictationContext, settings: &Personalization) {
    if let Some(style) = settings.app_styles.get(&ctx.bundle_id) {
        ctx.writing_style = style.clone();
    }
    // Prefer correct spellings for Whisper bias; keep distinct `heard` forms too
    // so product names the user actually says still land in the prompt.
    let mut vocab = Vec::new();
    let mut seen = std::collections::BTreeSet::new();
    for item in &settings.dictionary {
        for word in [&item.replace_with, &item.heard] {
            let trimmed = word.trim();
            if trimmed.is_empty() {
                continue;
            }
            let key = trimmed.to_lowercase();
            if !seen.insert(key) {
                continue;
            }
            vocab.push(trimmed.to_string());
            if vocab.len() >= 32 {
                break;
            }
        }
        if vocab.len() >= 32 {
            break;
        }
    }
    ctx.custom_vocabulary = vocab;
}

pub fn apply_replacements(text: &str, settings: &Personalization) -> String {
    let mut output = text.to_string();
    let mut rules = settings.dictionary.clone();
    rules.sort_by_key(|item| std::cmp::Reverse(item.heard.chars().count()));
    for rule in rules {
        let heard = rule.heard.trim();
        let replacement = rule.replace_with.trim();
        if heard.is_empty() || replacement.is_empty() {
            continue;
        }
        let re = regex::Regex::new(&format!(r"(?i){}", regex::escape(heard))).unwrap();
        output = re.replace_all(&output, replacement).into_owned();
    }
    output
}

pub fn expand_snippets(text: &str, settings: &Personalization) -> String {
    let mut output = text.to_string();
    let mut snippets = settings.snippets.clone();
    snippets.sort_by_key(|item| std::cmp::Reverse(item.trigger.chars().count()));
    for snippet in snippets {
        let trigger = snippet.trigger.trim();
        if trigger.is_empty() || snippet.expansion.is_empty() {
            continue;
        }
        let re = regex::Regex::new(&format!(
            r"(?i)(^|[\s\p{{P}}]){}([\s\p{{P}}]|$)",
            regex::escape(trigger)
        ))
        .unwrap();
        output = re
            .replace_all(&output, |caps: &regex::Captures| {
                format!("{}{}{}", &caps[1], snippet.expansion, &caps[2])
            })
            .into_owned();
    }
    output
}
