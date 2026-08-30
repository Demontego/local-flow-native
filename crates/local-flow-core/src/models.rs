use crate::config::EngineConfig;
use crate::error::{Error, Result};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

/// Russian fine-tune of Whisper base (ggml for whisper.cpp). Not bundled in .dmg.
/// Source: wabisabisocial/whisper-base-russian-ggml (CheeLi03/whisper-base-rus-8).
pub const WHISPER_FILENAME: &str = "ggml-base-ru.bin";
pub const WHISPER_URL: &str = concat!(
    "https://huggingface.co/wabisabisocial/whisper-base-russian-ggml/resolve/main/",
    "ggml-base-ru.bin"
);

/// Gemma 4 E2B instruct for cleanup (~3.2 GB). Not bundled in .dmg.
pub const LLM_FILENAME: &str = "gemma-4-E2B-it-Q4_K_M.gguf";
pub const LLM_URL: &str = concat!(
    "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/",
    "gemma-4-E2B-it-Q4_K_M.gguf"
);

#[derive(Debug, Clone, serde::Serialize)]
pub struct ModelsStatus {
    pub whisper: bool,
    pub llm: bool,
    pub whisper_path: String,
    pub llm_path: String,
}

pub fn status(cfg: &EngineConfig) -> ModelsStatus {
    let w = cfg.resolve_whisper_path();
    let l = cfg.llm_model.clone();
    ModelsStatus {
        whisper: whisper_ready(&w),
        llm: llm_ready(&l),
        whisper_path: w.display().to_string(),
        llm_path: l.display().to_string(),
    }
}

fn file_size(p: &Path) -> u64 {
    fs::metadata(p).map(|m| m.len()).unwrap_or(0)
}

pub fn ensure_models_dir(cfg: &EngineConfig) -> Result<PathBuf> {
    let dir = cfg.data_dir.join("models");
    fs::create_dir_all(&dir)?;
    Ok(dir)
}

/// Outcome of a model fetch: path + whether network was skipped.
#[derive(Debug, Clone)]
pub struct DownloadResult {
    pub path: PathBuf,
    pub already_present: bool,
}

impl DownloadResult {
    /// Wire format for shells: `already:<path>` or `<path>`.
    pub fn to_wire(&self) -> String {
        let p = self.path.display().to_string();
        if self.already_present {
            format!("already:{p}")
        } else {
            p
        }
    }
}

fn whisper_ready(path: &Path) -> bool {
    // ggml-base-ru ≈ 141 MB
    path.exists() && file_size(path) > 50_000_000
}

fn llm_ready(path: &Path) -> bool {
    path.exists() && file_size(path) > 500_000_000
}

/// Download `url` to `dest` unless `existing` already passes `ready`.
/// Progress via callback percent 0..=100. Writes to a `.partial` then renames.
fn download_if_missing(
    cfg: &EngineConfig,
    existing: &Path,
    dest: PathBuf,
    url: &str,
    ready: fn(&Path) -> bool,
    mut on_progress: impl FnMut(u32),
) -> Result<DownloadResult> {
    if ready(existing) {
        on_progress(100);
        return Ok(DownloadResult {
            path: existing.to_path_buf(),
            already_present: true,
        });
    }
    ensure_models_dir(cfg)?;
    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = dest.with_extension("partial");
    download_url(url, &tmp, &mut on_progress)?;
    fs::rename(&tmp, &dest)?;
    on_progress(100);
    Ok(DownloadResult {
        path: dest,
        already_present: false,
    })
}

/// Download whisper ggml if missing. Progress via callback percent 0..=100.
pub fn download_whisper(
    cfg: &EngineConfig,
    on_progress: impl FnMut(u32),
) -> Result<DownloadResult> {
    let existing = cfg.resolve_whisper_path();
    download_if_missing(
        cfg,
        &existing,
        cfg.whisper_model.clone(),
        WHISPER_URL,
        whisper_ready,
        on_progress,
    )
}

/// Download Gemma 4 E2B Q4_K_M GGUF (~3.2 GB). Name kept for FFI compat.
pub fn download_qwen(
    cfg: &EngineConfig,
    on_progress: impl FnMut(u32),
) -> Result<DownloadResult> {
    let dest = cfg.llm_model.clone();
    download_if_missing(cfg, &dest.clone(), dest, LLM_URL, llm_ready, on_progress)
}

fn download_url(url: &str, dest: &Path, on_progress: &mut impl FnMut(u32)) -> Result<()> {
    let mut resp = ureq::get(url)
        .call()
        .map_err(|e| Error::msg(format!("download: {e}")))?;
    let len = resp
        .headers()
        .get("Content-Length")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(0);
    let mut reader = resp.body_mut().as_reader();
    let mut file = fs::File::create(dest)?;
    let mut buf = [0u8; 1024 * 64];
    let mut done = 0u64;
    let mut last_pct = 0u32;
    on_progress(0);
    loop {
        let n = reader.read(&mut buf)?;
        if n == 0 {
            break;
        }
        std::io::Write::write_all(&mut file, &buf[..n])?;
        done += n as u64;
        if len > 0 {
            let pct = ((done * 100) / len) as u32;
            if pct != last_pct {
                last_pct = pct;
                on_progress(pct.min(99));
            }
        }
    }
    on_progress(100);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::EngineConfig;

    #[test]
    fn model_paths_are_inside_supplied_data_dir() {
        let temp = tempfile::tempdir().expect("tempdir");
        let cfg = EngineConfig::new(temp.path());
        assert_eq!(
            ensure_models_dir(&cfg).expect("models dir"),
            temp.path().join("models")
        );
        assert_eq!(cfg.llm_model, temp.path().join("models").join(LLM_FILENAME));

        let result = DownloadResult {
            path: cfg.llm_model,
            already_present: true,
        };
        assert!(result.to_wire().starts_with("already:"));
    }
}
