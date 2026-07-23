//! Auto-dictionary: suggest replacements from pasted vs user-edited text.

use crate::personalization::{self, Personalization, Replacement};
use crate::error::Result;
use std::path::Path;

/// Suggest heard→replace_with pairs from a paste that the user later edited.
/// Ignores pure case/punctuation-only diffs; prefers short phrase swaps.
pub fn suggest_replacements(pasted: &str, edited: &str) -> Vec<Replacement> {
    let pasted = pasted.trim();
    let edited = edited.trim();
    if pasted.is_empty() || edited.is_empty() || pasted == edited {
        return Vec::new();
    }
    // Whole-string rewrite when lengths are similar and few words differ.
    let a = tokenize(pasted);
    let b = tokenize(edited);
    if a.is_empty() || b.is_empty() {
        return Vec::new();
    }

    let mut out = Vec::new();

    // Equal-length token alignment: collect contiguous mismatch runs.
    if a.len() == b.len() {
        let mut i = 0;
        while i < a.len() {
            if norm(&a[i]) == norm(&b[i]) {
                i += 1;
                continue;
            }
            let start = i;
            while i < a.len() && norm(&a[i]) != norm(&b[i]) {
                i += 1;
            }
            let heard = a[start..i].join(" ");
            let replace_with = b[start..i].join(" ");
            if usable_pair(&heard, &replace_with) {
                out.push(Replacement {
                    heard,
                    replace_with,
                });
            }
        }
        return dedupe(out);
    }

    // Single token substitution when word counts differ by at most 2.
    if a.len().abs_diff(b.len()) <= 2 {
        // LCS-ish: find first mismatch and last match from end.
        let mut pre = 0;
        while pre < a.len().min(b.len()) && norm(&a[pre]) == norm(&b[pre]) {
            pre += 1;
        }
        let mut asuf = 0;
        let mut bsuf = 0;
        while asuf < a.len().saturating_sub(pre)
            && bsuf < b.len().saturating_sub(pre)
            && norm(&a[a.len() - 1 - asuf]) == norm(&b[b.len() - 1 - bsuf])
        {
            asuf += 1;
            bsuf += 1;
        }
        if pre + asuf < a.len() || pre + bsuf < b.len() {
            let heard = a[pre..a.len() - asuf].join(" ");
            let replace_with = b[pre..b.len() - bsuf].join(" ");
            if usable_pair(&heard, &replace_with) {
                out.push(Replacement {
                    heard,
                    replace_with,
                });
            }
        }
    }

    // Fallback: if edited is a short rewrite of a short paste, learn whole phrase.
    if out.is_empty()
        && a.len() <= 6
        && b.len() <= 6
        && pasted.chars().count() <= 48
        && edited.chars().count() <= 48
        && usable_pair(pasted, edited)
    {
        out.push(Replacement {
            heard: pasted.to_string(),
            replace_with: edited.to_string(),
        });
    }

    dedupe(out)
}

fn tokenize(s: &str) -> Vec<String> {
    s.split_whitespace()
        .map(|w| w.trim_matches(|c: char| c.is_ascii_punctuation()).to_string())
        .filter(|w| !w.is_empty())
        .collect()
}

fn norm(s: &str) -> String {
    s.to_lowercase()
}

fn usable_pair(heard: &str, replace_with: &str) -> bool {
    let h = heard.trim();
    let r = replace_with.trim();
    if h.is_empty() || r.is_empty() || norm(h) == norm(r) {
        return false;
    }
    if h.chars().count() > 64 || r.chars().count() > 64 {
        return false;
    }
    // Skip pure digit / single-char noise.
    if h.chars().count() == 1 && r.chars().count() == 1 {
        return false;
    }
    // Mid-edit (user still typing a long word): same long suffix, different stem
    // e.g. поавтемизировал → помизировал while aiming for персонализировал.
    if looks_like_mid_edit(h, r) {
        return false;
    }
    true
}

fn looks_like_mid_edit(heard: &str, edited: &str) -> bool {
    let h: Vec<char> = heard.chars().collect();
    let e: Vec<char> = edited.chars().collect();
    if h.len() < 8 || e.len() < 5 {
        return false;
    }
    // Single-token-ish: no spaces.
    if heard.contains(char::is_whitespace) || edited.contains(char::is_whitespace) {
        return false;
    }
    let suf = 6usize.min(h.len()).min(e.len());
    if h[h.len() - suf..] == e[e.len() - suf..] && h.len() != e.len() {
        return true;
    }
    // Edited is a short prefix of heard (deleted a lot, still typing).
    if e.len() + 3 < h.len() {
        let pref = e.len().min(4);
        if pref >= 3 && h[..pref] == e[..pref] {
            return true;
        }
    }
    false
}

fn dedupe(items: Vec<Replacement>) -> Vec<Replacement> {
    let mut out = Vec::new();
    for item in items {
        if out
            .iter()
            .any(|r: &Replacement| norm(&r.heard) == norm(&item.heard))
        {
            continue;
        }
        out.push(item);
    }
    out
}

/// Merge suggestions into personalization dictionary. Returns how many added.
pub fn accept_replacements(data: &Path, suggestions: &[Replacement]) -> Result<usize> {
    if suggestions.is_empty() {
        return Ok(0);
    }
    let mut settings = personalization::load(data);
    let mut added = 0;
    for s in suggestions {
        let heard = s.heard.trim();
        let replace_with = s.replace_with.trim();
        if !usable_pair(heard, replace_with) {
            continue;
        }
        if settings
            .dictionary
            .iter()
            .any(|r| norm(&r.heard) == norm(heard))
        {
            // Update existing mapping.
            if let Some(r) = settings
                .dictionary
                .iter_mut()
                .find(|r| norm(&r.heard) == norm(heard))
            {
                if r.replace_with != replace_with {
                    r.replace_with = replace_with.to_string();
                    added += 1;
                }
            }
            continue;
        }
        settings.dictionary.push(Replacement {
            heard: heard.to_string(),
            replace_with: replace_with.to_string(),
        });
        added += 1;
    }
    settings
        .dictionary
        .sort_by_key(|r| std::cmp::Reverse(r.heard.chars().count()));
    personalization::save(data, &settings)?;
    Ok(added)
}

/// Remove a dictionary rule by heard phrase (case-insensitive).
pub fn undo_replacement(data: &Path, heard: &str) -> Result<bool> {
    let mut settings = personalization::load(data);
    let before = settings.dictionary.len();
    let key = norm(heard.trim());
    settings.dictionary.retain(|r| norm(&r.heard) != key);
    let removed = settings.dictionary.len() != before;
    if removed {
        personalization::save(data, &settings)?;
    }
    Ok(removed)
}

pub fn learn_from_edit(data: &Path, pasted: &str, edited: &str) -> Result<Vec<Replacement>> {
    let suggestions = suggest_replacements(pasted, edited);
    accept_replacements(data, &suggestions)?;
    Ok(suggestions)
}

/// JSON helper for FFI.
pub fn dictionary_json(settings: &Personalization) -> String {
    serde_json::to_string(&settings.dictionary).unwrap_or_else(|_| "[]".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn learns_single_word_swap() {
        let s = suggest_replacements(
            "проверка голосового вода в Cursor",
            "проверка голосового ввода в Cursor",
        );
        assert!(
            s.iter().any(|r| r.heard.contains("вода") && r.replace_with.contains("ввода")),
            "{s:?}"
        );
    }

    #[test]
    fn ignores_identical() {
        assert!(suggest_replacements("привет", "привет").is_empty());
    }

    #[test]
    fn ignores_mid_edit_same_suffix() {
        // User mid-way fixing ASR while still typing the intended word.
        assert!(
            suggest_replacements("поавтемизировал", "помизировал").is_empty(),
            "must not learn incomplete edits"
        );
    }
}
