use crate::error::Result;
use std::fs;
use std::path::{Path, PathBuf};

const LIMIT: usize = 8;

pub fn history_dir(cache: &Path) -> PathBuf {
    cache.join("history")
}

fn path_for(cache: &Path, bundle_id: &str) -> PathBuf {
    let safe: String = bundle_id
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect();
    history_dir(cache).join(format!("{safe}.json"))
}

pub fn load_recent(cache: &Path, bundle_id: &str) -> Vec<String> {
    let path = path_for(cache, bundle_id);
    let Ok(data) = fs::read_to_string(path) else {
        return Vec::new();
    };
    serde_json::from_str(&data).unwrap_or_default()
}

pub fn save_recent(cache: &Path, bundle_id: &str, text: &str) -> Result<()> {
    let text = text.trim();
    if text.is_empty() || bundle_id.is_empty() {
        return Ok(());
    }
    fs::create_dir_all(history_dir(cache))?;
    let mut items = load_recent(cache, bundle_id);
    if items.last().map(|s| s.as_str()) == Some(text) {
        return Ok(());
    }
    items.push(text.to_string());
    if items.len() > LIMIT {
        items.drain(0..items.len() - LIMIT);
    }
    let data = serde_json::to_string_pretty(&items).map_err(|e| crate::Error::msg(e.to_string()))?;
    fs::write(path_for(cache, bundle_id), data)?;
    Ok(())
}
