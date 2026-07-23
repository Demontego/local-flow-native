//! Local Hub: dictation stats, session log, scratch notes, streak.

use crate::error::{Error, Result};
use serde::{Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum DictationDestination {
    #[default]
    Field,
    ScratchPad,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionEvent {
    pub ts: String,
    pub raw_len: usize,
    pub clean_len: usize,
    pub word_count: usize,
    pub bundle_id: String,
    pub mode: DictationDestination,
    #[serde(default)]
    pub preview: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Note {
    pub id: String,
    pub ts: String,
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct NotesFile {
    pub notes: Vec<Note>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct StatsFile {
    /// YYYY-MM-DD → words dictated that day.
    pub words_by_day: std::collections::BTreeMap<String, u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatsSummary {
    pub words_today: u64,
    pub words_week: u64,
    pub streak_days: u32,
    pub sessions_today: u32,
    pub last_preview: String,
}

fn hub_dir(data: &Path) -> PathBuf {
    data.join("hub")
}

fn sessions_path(data: &Path) -> PathBuf {
    hub_dir(data).join("sessions.jsonl")
}

fn stats_path(data: &Path) -> PathBuf {
    hub_dir(data).join("stats.json")
}

fn notes_path(data: &Path) -> PathBuf {
    hub_dir(data).join("notes.json")
}

fn today() -> String {
    // UTC date is fine for local streak; shells are single-user.
    chrono_lite_today()
}

/// Minimal YYYY-MM-DD without chrono dep.
fn chrono_lite_today() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // Approximate civil date from unix days (UTC).
    let days = (secs / 86_400) as i64;
    civil_from_days(days)
}

fn civil_from_days(mut z: i64) -> String {
    // Howard Hinnant algorithm
    z += 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}-{m:02}-{d:02}")
}

fn now_rfc3339() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("{secs}")
}

pub fn word_count(text: &str) -> usize {
    text.split_whitespace().filter(|w| !w.is_empty()).count()
}

pub fn record_dictation(
    data: &Path,
    raw: &str,
    clean: &str,
    bundle_id: &str,
    mode: DictationDestination,
) -> Result<()> {
    let clean = clean.trim();
    if clean.is_empty() || clean.starts_with("empty:") || clean.starts_with("error:") {
        return Ok(());
    }
    fs::create_dir_all(hub_dir(data))?;
    let words = word_count(clean) as u64;
    let day = today();

    let mut stats = load_stats(data);
    *stats.words_by_day.entry(day).or_insert(0) += words;
    save_stats(data, &stats)?;

    let preview: String = clean.chars().take(120).collect();
    let ev = SessionEvent {
        ts: now_rfc3339(),
        raw_len: raw.chars().count(),
        clean_len: clean.chars().count(),
        word_count: words as usize,
        bundle_id: bundle_id.to_string(),
        mode,
        preview,
    };
    let mut f = OpenOptions::new()
        .create(true)
        .append(true)
        .open(sessions_path(data))?;
    writeln!(
        f,
        "{}",
        serde_json::to_string(&ev).map_err(|e| Error::msg(e.to_string()))?
    )?;
    Ok(())
}

fn load_stats(data: &Path) -> StatsFile {
    let Ok(s) = fs::read_to_string(stats_path(data)) else {
        return StatsFile::default();
    };
    serde_json::from_str(&s).unwrap_or_default()
}

fn save_stats(data: &Path, stats: &StatsFile) -> Result<()> {
    fs::create_dir_all(hub_dir(data))?;
    let json = serde_json::to_string_pretty(stats).map_err(|e| Error::msg(e.to_string()))?;
    fs::write(stats_path(data), json)?;
    Ok(())
}

pub fn stats_summary(data: &Path) -> StatsSummary {
    let stats = load_stats(data);
    let today = today();
    let words_today = *stats.words_by_day.get(&today).unwrap_or(&0);
    let mut words_week = 0u64;
    // Last 7 calendar keys lexicographic works for YYYY-MM-DD.
    let keys: Vec<_> = stats.words_by_day.keys().cloned().collect();
    for k in keys.iter().rev().take(7) {
        words_week += stats.words_by_day.get(k).copied().unwrap_or(0);
    }
    let streak = streak_days(&stats, &today);
    let sessions = list_recent_sessions(data, 200);
    let sessions_today = sessions
        .iter()
        .filter(|s| {
            // ts is unix secs string
            let Ok(secs) = s.ts.parse::<u64>() else {
                return false;
            };
            let day = civil_from_days((secs / 86_400) as i64);
            day == today
        })
        .count() as u32;
    let last_preview = sessions.first().map(|s| s.preview.clone()).unwrap_or_default();
    StatsSummary {
        words_today,
        words_week,
        streak_days: streak,
        sessions_today,
        last_preview,
    }
}

fn streak_days(stats: &StatsFile, today: &str) -> u32 {
    let mut streak = 0u32;
    let Ok(today_days) = ymd_to_days(today) else {
        return 0;
    };
    for offset in 0..365 {
        let day = civil_from_days(today_days - offset);
        let words = stats.words_by_day.get(&day).copied().unwrap_or(0);
        if words == 0 {
            break;
        }
        streak += 1;
    }
    streak
}

fn ymd_to_days(ymd: &str) -> std::result::Result<i64, ()> {
    let mut parts = ymd.split('-');
    let y: i64 = parts.next().ok_or(())?.parse().map_err(|_| ())?;
    let m: u32 = parts.next().ok_or(())?.parse().map_err(|_| ())?;
    let d: u32 = parts.next().ok_or(())?.parse().map_err(|_| ())?;
    // Inverse of civil_from_days (Hinnant)
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = (y - era * 400) as u64;
    let mp = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mp as u64 + 2) / 5 + d as u64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    Ok(era * 146_097 + doe as i64 - 719_468)
}

pub fn list_recent_sessions(data: &Path, limit: usize) -> Vec<SessionEvent> {
    let Ok(f) = fs::File::open(sessions_path(data)) else {
        return Vec::new();
    };
    let mut items = Vec::new();
    for line in BufReader::new(f).lines().flatten() {
        if let Ok(ev) = serde_json::from_str::<SessionEvent>(&line) {
            items.push(ev);
        }
    }
    items.reverse();
    items.truncate(limit);
    items
}

pub fn list_notes(data: &Path) -> Vec<Note> {
    load_notes(data).notes
}

fn load_notes(data: &Path) -> NotesFile {
    let Ok(s) = fs::read_to_string(notes_path(data)) else {
        return NotesFile::default();
    };
    serde_json::from_str(&s).unwrap_or_default()
}

fn save_notes(data: &Path, notes: &NotesFile) -> Result<()> {
    fs::create_dir_all(hub_dir(data))?;
    let json = serde_json::to_string_pretty(notes).map_err(|e| Error::msg(e.to_string()))?;
    fs::write(notes_path(data), json)?;
    Ok(())
}

pub fn add_note(data: &Path, text: &str) -> Result<Note> {
    let text = text.trim();
    if text.is_empty() {
        return Err(Error::msg("empty note"));
    }
    let mut file = load_notes(data);
    let note = Note {
        id: format!("n{}", now_rfc3339()),
        ts: now_rfc3339(),
        text: text.to_string(),
    };
    file.notes.insert(0, note.clone());
    file.notes.truncate(200);
    save_notes(data, &file)?;
    Ok(note)
}

pub fn delete_note(data: &Path, id: &str) -> Result<()> {
    let mut file = load_notes(data);
    file.notes.retain(|n| n.id != id);
    save_notes(data, &file)
}

pub fn hub_snapshot_json(data: &Path) -> Result<String> {
    #[derive(Serialize)]
    struct Snap {
        stats: StatsSummary,
        sessions: Vec<SessionEvent>,
        notes: Vec<Note>,
    }
    let snap = Snap {
        stats: stats_summary(data),
        sessions: list_recent_sessions(data, 50),
        notes: list_notes(data),
    };
    serde_json::to_string(&snap).map_err(|e| Error::msg(e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn records_stats_and_note() {
        let tmp = TempDir::new().unwrap();
        record_dictation(
            tmp.path(),
            "сырой",
            "привет мир",
            "com.test",
            DictationDestination::Field,
        )
        .unwrap();
        let s = stats_summary(tmp.path());
        assert!(s.words_today >= 2);
        assert_eq!(list_recent_sessions(tmp.path(), 10).len(), 1);
        add_note(tmp.path(), "scratch hello").unwrap();
        assert_eq!(list_notes(tmp.path()).len(), 1);
    }
}
