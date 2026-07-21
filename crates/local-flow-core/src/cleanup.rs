use crate::context::DictationContext;
use crate::error::{Error, Result};
use std::path::Path;
use std::sync::Arc;

pub const DEFAULT_PROMPT: &str = include_str!("../../../prompts/cleanup.txt");

pub trait CleanupBackend: Send + Sync {
    fn cleanup(&self, raw: &str, ctx: &DictationContext) -> Result<String>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SmartFormat {
    pub text: String,
    pub press_enter: bool,
}

/// Deterministic spoken punctuation and conservative self-correction.
/// Kept separate from Qwen so local/heuristic mode has the same controls.
pub fn smart_format(raw: &str) -> SmartFormat {
    let mut text = raw.trim().to_string();
    let press_enter = strip_trailing_enter(&mut text);
    text = backtrack(&text);
    text = numbered_list(&text);
    for (spoken, symbol) in [
        ("новый абзац", "\n\n"),
        ("новая строка", "\n"),
        ("следующая строка", "\n"),
        ("точка с запятой", ";"),
        ("восклицательный знак", "!"),
        ("вопросительный знак", "?"),
        ("двоеточие", ":"),
        ("запятая", ","),
        ("точка", "."),
        ("тире", " — "),
    ] {
        text = replace_ci(&text, spoken, symbol);
    }
    SmartFormat {
        text: normalize_format_whitespace(&text),
        press_enter,
    }
}

fn strip_trailing_enter(text: &mut String) -> bool {
    let re = regex::Regex::new(
        r"(?i)(?:[\s,.;:!?]+)?(?:нажми\s+enter|нажать\s+enter|press\s+enter)\s*[.!?]?\s*$",
    )
    .unwrap();
    if !re.is_match(text) {
        return false;
    }
    *text = re.replace(text, "").trim_end().to_string();
    true
}

fn backtrack(text: &str) -> String {
    // Deliberately narrow: only an explicit correction of a numeric time/quantity.
    // "Я вообще-то дома" must remain untouched.
    let re = regex::Regex::new(
        r"(?i)\b(в|на|к)\s+(\d+)\s*,?\s*(?:нет|точнее|вернее)\s*,?\s*(?:(?:в|на|к)\s+)?(\d+)\b",
    )
    .unwrap();
    re.replace_all(text, "$1 $3").into_owned()
}

fn numbered_list(text: &str) -> String {
    let re = regex::Regex::new(r"(?i)\bперв(?:ое|ый)\s+(.+?)\s+втор(?:ое|ой)\s+(.+)$").unwrap();
    re.replace(text, "1. $1\n2. $2").into_owned()
}

fn normalize_format_whitespace(text: &str) -> String {
    text.lines()
        .map(|line| {
            collapse_ws(line)
                .replace(" ,", ",")
                .replace(" .", ".")
                .replace(" !", "!")
                .replace(" ?", "?")
                .replace(" :", ":")
                .replace(" ;", ";")
        })
        .collect::<Vec<_>>()
        .join("\n")
        .replace("\n \n", "\n\n")
        .trim()
        .to_string()
}

/// Heuristic fallback when GGUF model is missing (keeps shell usable).
pub struct HeuristicCleanup;

impl CleanupBackend for HeuristicCleanup {
    fn cleanup(&self, raw: &str, ctx: &DictationContext) -> Result<String> {
        Ok(heuristic_polish(raw, ctx))
    }
}

pub fn heuristic_polish(raw: &str, ctx: &DictationContext) -> String {
    let mut t = raw.trim().to_string();
    for filler in ["ну типа ", "ну ", "типа ", "ээ ", "эм ", "hmm ", "uh "] {
        while let Some(rest) = t.strip_prefix(filler) {
            t = rest.to_string();
        }
        t = t.replace(filler, " ");
    }
    t = asr_homophone_fix(&t, ctx);
    t = collapse_ws(&t);
    capitalize_sentence(&t)
}

/// Reject cleanup that likely summarized or hallucinated instead of polishing ASR.
/// Short utterances stay permissive because a single dictionary correction changes
/// every token (for example, "газового вода" → "голосового ввода").
pub fn accepts_cleanup(raw: &str, candidate: &str, ctx: &DictationContext) -> bool {
    let raw = asr_homophone_fix(raw, ctx);
    let candidate = candidate.trim();
    if candidate.is_empty() {
        return false;
    }

    let raw_words = meaningful_words(&raw);
    if candidate.chars().count() * 100 < raw.chars().count() * 45 {
        return false;
    }
    if raw_words.len() <= 4 {
        return true;
    }

    let candidate_words = meaningful_words(candidate);
    if candidate_words.len() < 2 {
        return false;
    }

    let retained = raw_words
        .iter()
        .filter(|word| candidate_words.iter().any(|candidate| candidate == *word))
        .count();
    retained * 100 >= raw_words.len() * 60
}

fn meaningful_words(text: &str) -> Vec<String> {
    const FILLERS: &[&str] = &["ну", "типа", "ээ", "эм", "hmm", "uh", "like"];
    text.split(|c: char| !c.is_alphanumeric())
        .map(|word| word.to_lowercase())
        .filter(|word| word.len() > 1 && !FILLERS.contains(&word.as_str()))
        .collect()
}

/// Deterministic Whisper-RU fixes. Applied after Qwen too — model often keeps these.
pub fn asr_homophone_fix(raw: &str, ctx: &DictationContext) -> String {
    let mut t = raw.to_string();
    // Phrase-level first (order matters).
    let phrases: &[(&str, &str)] = &[
        ("газового вода", "голосового ввода"),
        ("газового ввода", "голосового ввода"),
        ("газовой воды", "голосового ввода"),
        ("газовая вода", "голосовой ввод"),
        ("газовый вода", "голосовой ввод"),
        ("газовый ввод", "голосовой ввод"),
        ("газовая ввода", "голосового ввода"),
        ("голосового вода", "голосового ввода"),
        ("голосовой вода", "голосовой ввод"),
        ("в куроре", "в курсоре"),
        ("в кур соре", "в курсоре"),
    ];
    for (from, to) in phrases {
        t = replace_ci(&t, from, to);
    }
    if ctx.is_tech_chat() || ctx.is_editor() {
        t = regex_replace_word(&t, "кот", "код");
        t = regex_replace_word(&t, "кота", "кода");
        t = regex_replace_word(&t, "коту", "коду");
        // Lone "газового/газовый" almost always "голосового" in editor dictation.
        t = regex_replace_word(&t, "газового", "голосового");
        t = regex_replace_word(&t, "газовый", "голосовой");
        t = regex_replace_word(&t, "газовой", "голосовой");
        t = regex_replace_word(&t, "газовое", "голосовое");
    }
    t
}

fn replace_ci(text: &str, from: &str, to: &str) -> String {
    let re = regex::Regex::new(&format!("(?i){}", regex::escape(from))).unwrap();
    re.replace_all(text, to).into_owned()
}

fn regex_replace_word(text: &str, from: &str, to: &str) -> String {
    // No lookaround (default regex). Delimiters captured on both sides.
    let re = regex::Regex::new(&format!(
        r"(?i)(^|[\s\p{{P}}]){}([\s\p{{P}}]|$)",
        regex::escape(from)
    ))
    .unwrap();
    re.replace_all(text, |caps: &regex::Captures| {
        format!("{}{}{}", &caps[1], to, &caps[2])
    })
    .into_owned()
}

fn collapse_ws(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn capitalize_sentence(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        None => String::new(),
        Some(f) => {
            let mut out = f.to_uppercase().collect::<String>();
            out.push_str(c.as_str());
            if !out.ends_with(['.', '!', '?']) {
                out.push('.');
            }
            out
        }
    }
}

fn strip_model_noise(text: &str) -> String {
    let mut t = text.trim().to_string();
    if let Some(idx) = t.rfind("</think>") {
        t = t[idx + "</think>".len()..].trim().to_string();
    }
    if t.len() >= 2 && t.starts_with('"') && t.ends_with('"') {
        t = t[1..t.len() - 1].to_string();
    }
    t.trim().to_string()
}

pub struct CleanupEngine {
    inner: Arc<dyn CleanupBackend>,
    pub backend_name: String,
}

impl CleanupEngine {
    pub fn heuristic() -> Self {
        Self {
            inner: Arc::new(HeuristicCleanup),
            backend_name: "heuristic".into(),
        }
    }

    pub fn load(model: &Path, system_prompt: &str) -> Result<Self> {
        if !model.exists() {
            return Err(Error::ModelMissing(model.display().to_string()));
        }
        #[cfg(feature = "llama")]
        {
            return Ok(Self {
                inner: Arc::new(llama_backend::LlamaCleanup::load(model, system_prompt)?),
                backend_name: "qwen3".into(),
            });
        }
        #[cfg(not(feature = "llama"))]
        {
            let _ = system_prompt;
            Err(Error::msg("llama feature disabled at build time"))
        }
    }

    pub fn cleanup(&self, raw: &str, ctx: &DictationContext) -> Result<String> {
        let mut out = strip_model_noise(&self.inner.cleanup(raw, ctx)?);
        out = asr_homophone_fix(&out, ctx);
        out = collapse_ws(&out);
        Ok(out)
    }
}

#[cfg(feature = "llama")]
mod llama_backend {
    use super::*;
    use llama_cpp_2::context::params::LlamaContextParams;
    use llama_cpp_2::llama_backend::LlamaBackend;
    use llama_cpp_2::llama_batch::LlamaBatch;
    use llama_cpp_2::model::params::LlamaModelParams;
    use llama_cpp_2::model::{AddBos, LlamaChatMessage, LlamaModel};
    use llama_cpp_2::sampling::LlamaSampler;
    use parking_lot::Mutex;
    use std::num::NonZeroU32;
    use std::sync::OnceLock;

    /// Process-wide backend. Owning `LlamaBackend` inside the engine is unsafe to
    /// reload: `Drop` calls `llama_backend_free`, and a second `init` fails with
    /// `BackendAlreadyInitialized` → silent fallback to heuristic.
    fn shared_backend() -> Result<&'static LlamaBackend> {
        static BACKEND: OnceLock<LlamaBackend> = OnceLock::new();
        if let Some(b) = BACKEND.get() {
            return Ok(b);
        }
        // init only once; raced callers see AlreadyInitialized and retry get()
        match LlamaBackend::init() {
            Ok(b) => {
                let _ = BACKEND.set(b);
            }
            Err(e) => {
                if BACKEND.get().is_none() {
                    return Err(Error::Cleanup(e.to_string()));
                }
            }
        }
        BACKEND
            .get()
            .ok_or_else(|| Error::Cleanup("llama backend not initialized".into()))
    }

    pub struct LlamaCleanup {
        model: LlamaModel,
        system: String,
        lock: Mutex<()>,
    }

    impl LlamaCleanup {
        pub fn load(model_path: &Path, system_prompt: &str) -> Result<Self> {
            let backend = shared_backend()?;
            let model =
                LlamaModel::load_from_file(backend, model_path, &LlamaModelParams::default())
                    .map_err(|e| Error::Cleanup(format!("load gguf: {e}")))?;
            Ok(Self {
                model,
                system: system_prompt.to_string(),
                lock: Mutex::new(()),
            })
        }
    }

    impl CleanupBackend for LlamaCleanup {
        fn cleanup(&self, raw: &str, ctx: &DictationContext) -> Result<String> {
            let _guard = self.lock.lock();
            // Compact context — huge AX dumps blow n_ctx and ggml_abort in sampler.
            let block = truncate_chars(&ctx.to_prompt_block(), 1800);
            let raw = truncate_chars(raw.trim(), 800);
            // /no_think — Qwen3 thinking mode off (faster, no <think> dump)
            let user = format!(
                "/no_think\n\
                 Clean dictation for the focused app/window. \
                 Use app + window title + context for homophones. \
                 Keep spaces between words. Output only final text.\n\n\
                 {block}\n\n\
                 Dictation:\n\n{raw}"
            );
            let msgs = [
                LlamaChatMessage::new("system".into(), self.system.clone())
                    .map_err(|e| Error::Cleanup(e.to_string()))?,
                LlamaChatMessage::new("user".into(), user)
                    .map_err(|e| Error::Cleanup(e.to_string()))?,
            ];
            let tmpl = self
                .model
                .chat_template(None)
                .map_err(|e| Error::Cleanup(format!("chat template: {e}")))?;
            let prompt = self
                .model
                .apply_chat_template(&tmpl, &msgs, true)
                .map_err(|e| Error::Cleanup(e.to_string()))?;

            const N_CTX: u32 = 4096;
            const N_GEN: usize = 128;
            let ctx_params =
                LlamaContextParams::default().with_n_ctx(Some(NonZeroU32::new(N_CTX).unwrap()));
            let mut lctx = self
                .model
                .new_context(shared_backend()?, ctx_params)
                .map_err(|e| Error::Cleanup(e.to_string()))?;

            let mut tokens = self
                .model
                .str_to_token(&prompt, AddBos::Always)
                .map_err(|e| Error::Cleanup(e.to_string()))?;
            if tokens.is_empty() {
                return Err(Error::Cleanup("empty prompt tokens".into()));
            }
            let max_prompt = (N_CTX as usize).saturating_sub(N_GEN);
            if tokens.len() > max_prompt {
                // Keep BOS + tail (instruction end + dictation matter most).
                let bos = tokens[0];
                let skip = tokens.len() - (max_prompt - 1);
                tokens = std::iter::once(bos)
                    .chain(tokens.into_iter().skip(skip))
                    .collect();
            }

            let n = tokens.len();
            let mut batch = LlamaBatch::new(n.max(512), 1);
            let last = n - 1;
            for (i, token) in tokens.into_iter().enumerate() {
                batch
                    .add(token, i as i32, &[0], i == last)
                    .map_err(|e| Error::Cleanup(e.to_string()))?;
            }
            lctx.decode(&mut batch)
                .map_err(|e| Error::Cleanup(e.to_string()))?;

            // sample idx = -1 → last logits from the previous decode (only last
            // prompt token requested logits). Absolute pos (n-1) crashes:
            // get_logits_ith: batch.logits[i] != true
            let mut sampler =
                LlamaSampler::chain_simple([LlamaSampler::temp(0.0), LlamaSampler::greedy()]);
            let mut out = String::new();
            let mut n_cur = n as i32;
            for _ in 0..N_GEN {
                let token = sampler.sample(&lctx, -1);
                sampler.accept(token);
                if self.model.is_eog_token(token) {
                    break;
                }
                let bytes = self
                    .model
                    .token_to_piece_bytes(token, 32, false, None)
                    .map_err(|e| Error::Cleanup(e.to_string()))?;
                out.push_str(&String::from_utf8_lossy(&bytes));
                batch.clear();
                batch
                    .add(token, n_cur, &[0], true)
                    .map_err(|e| Error::Cleanup(e.to_string()))?;
                lctx.decode(&mut batch)
                    .map_err(|e| Error::Cleanup(e.to_string()))?;
                n_cur += 1;
            }
            Ok(out)
        }
    }

    fn truncate_chars(s: &str, max: usize) -> String {
        if s.chars().count() <= max {
            return s.to_string();
        }
        s.chars().take(max).collect::<String>() + "…"
    }
}
