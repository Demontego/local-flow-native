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

/// Collapse intra-line space runs and drop the space before punctuation.
fn fix_punct_spacing(line: &str) -> String {
    collapse_ws(line)
        .replace(" ,", ",")
        .replace(" .", ".")
        .replace(" !", "!")
        .replace(" ?", "?")
        .replace(" :", ":")
        .replace(" ;", ";")
}

/// Per-line spacing fix + a blank-run collapse pass. `collapse_blanks` is the
/// literal run reduced to a single blank line (`"\n \n"` vs `"\n\n\n"`).
fn normalize_lines(text: &str, collapse_blanks: &str) -> String {
    text.lines()
        .map(fix_punct_spacing)
        .collect::<Vec<_>>()
        .join("\n")
        .replace(collapse_blanks, "\n\n")
        .trim()
        .to_string()
}

fn normalize_format_whitespace(text: &str) -> String {
    normalize_lines(text, "\n \n")
}

/// Heuristic fallback when GGUF model is missing (keeps shell usable).
pub struct HeuristicCleanup;

impl CleanupBackend for HeuristicCleanup {
    fn cleanup(&self, raw: &str, ctx: &DictationContext) -> Result<String> {
        Ok(heuristic_polish(raw, ctx))
    }
}

pub fn heuristic_polish(raw: &str, _ctx: &DictationContext) -> String {
    let mut t = apply_common_asr_fixes(raw.trim());
    for filler in ["ну типа ", "ну ", "типа ", "ээ ", "эм ", "hmm ", "uh "] {
        while let Some(rest) = t.strip_prefix(filler) {
            t = rest.to_string();
        }
        t = t.replace(filler, " ");
    }
    t = collapse_ws(&t);
    capitalize_sentence(&t)
}

/// Small LLMs often echo ASR unchanged (paste.log). Deterministic fixes for
/// high-frequency RU phonetic → intended terms. Longer phrases first.
pub fn apply_common_asr_fixes(text: &str) -> String {
    let mut t = text.to_string();
    // Longer / more specific first (replace_ci is plain substring).
    for (from, to) in [
        ("голосового вода", "голосового ввода"),
        ("голосовое вода", "голосовой ввод"),
        ("газового вода", "голосового ввода"),
        ("велосипедового вода", "голосового ввода"),
        ("в курсуаре", "в Cursor"),
        ("в курсуоре", "в Cursor"),
        ("курсуаре", "Cursor"),
        ("пытаюсье", "пытаюсь"),
        ("вестите", "ввести"),
        ("веряем", "проверяем"),
        ("с точками запятыми", "с точками и запятыми"),
        ("с.ми запятыми", "с точками и запятыми"),
        ("гвен", "Qwen"),
        ("квен", "Qwen"),
        ("квэн", "Qwen"),
        ("пьен", "Qwen"),
        ("гемм-4", "Gemma 4"),
        ("гемма 4", "Gemma 4"),
        ("гемма4", "Gemma 4"),
        ("гемма", "Gemma"),
        ("виспер", "Whisper"),
        ("гитхаб", "GitHub"),
    ] {
        t = replace_ci(&t, from, to);
    }
    t
}

/// Reject cleanup that likely summarized or hallucinated instead of polishing ASR.
/// Phonetic / morphology fixes must pass — otherwise Gemma edits get thrown away.
pub fn accepts_cleanup(raw: &str, candidate: &str, _ctx: &DictationContext) -> bool {
    let candidate = candidate.trim();
    if candidate.is_empty() {
        return false;
    }

    let raw_words = meaningful_words(raw);
    let raw_len = raw.chars().count().max(1);
    let cand_len = candidate.chars().count();
    // Collapse = summary; large growth = invented from app context.
    if cand_len * 100 < raw_len * 55 || cand_len * 100 > raw_len * 140 {
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
        .filter(|word| candidate_words.iter().any(|c| words_align(word, c)))
        .count();
    // ASR repair changes many tokens; 50% fuzzy-align is enough to catch true summaries.
    if retained * 100 < raw_words.len() * 50 {
        return false;
    }

    // Reject prose lifted from UI: many new Cyrillic words not grounded in ASR.
    // ASCII tokens (Cursor, Qwen, …) are allowed as product-name fixes.
    let novel = candidate_words
        .iter()
        .filter(|c| {
            !raw_words.iter().any(|r| words_align(r, c)) && !is_ascii_product_token(c)
        })
        .count();
    if novel * 100 > candidate_words.len() * 30 {
        return false;
    }

    // Opening must stay at the start (reject mid-thought summaries that keep the tail).
    let open_n = raw_words.len().min(3);
    let cand_head = &candidate_words[..candidate_words.len().min(8)];
    let open_hits = raw_words[..open_n]
        .iter()
        .filter(|w| cand_head.iter().any(|c| words_align(w, c)))
        .count();
    open_hits * 100 >= open_n * 50
}

fn is_ascii_product_token(w: &str) -> bool {
    let n = w.chars().count();
    n >= 2 && n <= 24 && w.chars().all(|c| c.is_ascii_alphanumeric())
}

fn meaningful_words(text: &str) -> Vec<String> {
    const FILLERS: &[&str] = &["ну", "типа", "ээ", "эм", "hmm", "uh", "like"];
    text.split(|c: char| !c.is_alphanumeric())
        .map(|word| word.to_lowercase())
        .filter(|word| word.chars().count() > 1 && !FILLERS.contains(&word.as_str()))
        .collect()
}

/// Exact, stem, or small edit-distance match (вода↔ввода, курсуаре↔cursor).
fn words_align(a: &str, b: &str) -> bool {
    if a == b {
        return true;
    }
    let ac: Vec<char> = a.chars().collect();
    let bc: Vec<char> = b.chars().collect();
    if ac.is_empty() || bc.is_empty() {
        return false;
    }
    let min_c = ac.len().min(bc.len());
    let max_c = ac.len().max(bc.len());
    // Shared stem (morphology / ending noise).
    if min_c >= 4 {
        let stem = min_c.saturating_sub(2).max(4).min(min_c);
        if ac[..stem] == bc[..stem] {
            return true;
        }
    }
    // Short Levenshtein for ASR near-misses and Latin↔Cyrillic product names of similar length.
    if max_c <= 14 && min_c * 100 >= max_c * 45 {
        let dist = levenshtein(&ac, &bc);
        if dist <= 2 || (max_c >= 5 && dist * 100 <= max_c * 40) {
            return true;
        }
    }
    false
}

fn levenshtein(a: &[char], b: &[char]) -> usize {
    let (n, m) = (a.len(), b.len());
    if n == 0 {
        return m;
    }
    if m == 0 {
        return n;
    }
    let mut prev: Vec<usize> = (0..=m).collect();
    let mut cur = vec![0; m + 1];
    for i in 1..=n {
        cur[0] = i;
        for j in 1..=m {
            let cost = usize::from(a[i - 1] != b[j - 1]);
            cur[j] = (prev[j] + 1).min(cur[j - 1] + 1).min(prev[j - 1] + cost);
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    prev[m]
}

fn replace_ci(text: &str, from: &str, to: &str) -> String {
    let re = regex::Regex::new(&format!("(?i){}", regex::escape(from))).unwrap();
    re.replace_all(text, to).into_owned()
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
    // Qwen thinking / Gemma channel dumps — keep only final answer.
    for marker in ["</think>", "<|channel|>"] {
        if let Some(idx) = t.rfind(marker) {
            t = t[idx + marker.len()..].trim().to_string();
        }
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
                backend_name: "gemma4".into(),
            });
        }
        #[cfg(not(feature = "llama"))]
        {
            let _ = system_prompt;
            Err(Error::msg("llama feature disabled at build time"))
        }
    }

    pub fn cleanup(&self, raw: &str, ctx: &DictationContext) -> Result<String> {
        // Pre-fix so the LLM sees corrected terms; post-fix if it echoes ASR.
        let raw = apply_common_asr_fixes(raw);
        let mut out = strip_model_noise(&self.inner.cleanup(&raw, ctx)?);
        // Keep newlines / punctuation spacing Gemma added — only squash space runs.
        out = normalize_llm_whitespace(&out);
        out = apply_common_asr_fixes(&out);
        Ok(out)
    }
}

fn normalize_llm_whitespace(text: &str) -> String {
    normalize_lines(text, "\n\n\n")
}

#[cfg(feature = "llama")]
mod llama_backend {
    use super::*;
    use llama_cpp_2::context::params::LlamaContextParams;
    use llama_cpp_2::llama_backend::LlamaBackend;
    use llama_cpp_2::llama_batch::LlamaBatch;
    use llama_cpp_2::model::params::LlamaModelParams;
    use llama_cpp_2::model::{AddBos, LlamaModel};
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

    /// Enough for system + short dictation + gen; avoids per-call 3k alloc.
    const N_CTX: u32 = 1536;

    /// llama.cpp context is not marked Send; we only touch it under `LlamaCleanup::ctx`.
    struct OwnedCtx(llama_cpp_2::context::LlamaContext<'static>);
    // SAFETY: exclusive access via `Mutex` in `LlamaCleanup`; never shared across threads.
    unsafe impl Send for OwnedCtx {}

    pub struct LlamaCleanup {
        /// Declared before `model` so Drop frees context while the model still lives.
        ctx: Mutex<Option<OwnedCtx>>,
        model: LlamaModel,
        system: String,
    }

    impl LlamaCleanup {
        pub fn load(model_path: &Path, system_prompt: &str) -> Result<Self> {
            let backend = shared_backend()?;
            // Whisper stays CPU. Gemma: Metal on Apple; Vulkan when feature on.
            let n_gpu = if cfg!(any(target_os = "macos", target_os = "ios"))
                || cfg!(feature = "vulkan")
            {
                999
            } else {
                0
            };
            let params = LlamaModelParams::default().with_n_gpu_layers(n_gpu);
            let model = LlamaModel::load_from_file(backend, model_path, &params)
                .map_err(|e| Error::Cleanup(format!("load gguf: {e}")))?;
            // Full cleanup.txt is short enough; truncating it starved edit instructions.
            let system = truncate_chars(system_prompt.trim(), 1800);
            let n_threads = std::thread::available_parallelism()
                .map(|n| n.get() as i32)
                .unwrap_or(4)
                .clamp(2, 8);
            let ctx_params = LlamaContextParams::default()
                .with_n_ctx(Some(NonZeroU32::new(N_CTX).unwrap()))
                .with_n_batch(512)
                .with_n_ubatch(512)
                .with_n_threads(n_threads)
                .with_n_threads_batch(n_threads)
                .with_offload_kqv(true);
            let lctx = model
                .new_context(backend, ctx_params)
                .map_err(|e| Error::Cleanup(format!("new_context: {e}")))?;
            // SAFETY: `ctx` is dropped before `model` (field declaration order).
            // Lifetime is only a borrow of `model`; we never move `model` out.
            let lctx: llama_cpp_2::context::LlamaContext<'static> =
                unsafe { std::mem::transmute(lctx) };
            Ok(Self {
                ctx: Mutex::new(Some(OwnedCtx(lctx))),
                model,
                system,
            })
        }
    }

    impl CleanupBackend for LlamaCleanup {
        fn cleanup(&self, raw: &str, ctx: &DictationContext) -> Result<String> {
            let mut lctx_guard = self.ctx.lock();
            let lctx = &mut lctx_guard
                .as_mut()
                .ok_or_else(|| Error::Cleanup("llama context missing".into()))?
                .0;
            lctx.clear_kv_cache();

            let hint = truncate_chars(&ctx.to_cleanup_hint(), 200);
            let raw = truncate_chars(raw.trim(), 900);
            // Rules live in cleanup.txt / system — keep the user turn lean.
            let user = format!(
                "Dictation:\n{raw}\n\nHint (tone/vocab only, do not quote):\n{hint}\n\nCleaned text:"
            );
            // Gemma 4 Jinja chat_template fails in llama-cpp minja (ffi -1).
            let prompt = format_gemma4_prompt(&self.system, &user);

            // Room for punctuation + mild rewrites (not just echo).
            let n_gen = (raw.chars().count() * 3 / 4 + 64).clamp(96, 384);

            let mut tokens = self
                .model
                .str_to_token(&prompt, AddBos::Never)
                .map_err(|e| Error::Cleanup(format!("tokenize: {e}")))?;
            if tokens.is_empty() {
                return Err(Error::Cleanup("empty prompt tokens".into()));
            }
            let max_prompt = (N_CTX as usize).saturating_sub(n_gen);
            if tokens.len() > max_prompt {
                let head = tokens[0];
                let skip = tokens.len() - (max_prompt - 1);
                tokens = std::iter::once(head)
                    .chain(tokens.into_iter().skip(skip))
                    .collect();
            }

            let n = tokens.len();
            let mut batch = LlamaBatch::new(512, 1);
            let mut i = 0;
            while i < n {
                batch.clear();
                let end = (i + 512).min(n);
                for (j, &token) in tokens[i..end].iter().enumerate() {
                    let pos = (i + j) as i32;
                    let logits = i + j == n - 1;
                    batch
                        .add(token, pos, &[0], logits)
                        .map_err(|e| Error::Cleanup(format!("batch.add prompt@{pos}: {e}")))?;
                }
                lctx.decode(&mut batch)
                    .map_err(|e| Error::Cleanup(format!("decode prompt {i}..{end}/{n}: {e}")))?;
                i = end;
            }

            // Greedy only — temp+greedy was redundant (temp never sampled).
            let mut sampler = LlamaSampler::chain_simple([LlamaSampler::greedy()]);
            let mut out = String::new();
            let mut n_cur = n as i32;
            let n_ctx = N_CTX as i32;
            for step in 0..n_gen {
                if n_cur >= n_ctx {
                    break;
                }
                let token = sampler.sample(lctx, -1);
                sampler.accept(token);
                if self.model.is_eog_token(token) {
                    break;
                }
                let bytes = self
                    .model
                    .token_to_piece_bytes(token, 32, false, None)
                    .map_err(|e| Error::Cleanup(format!("token_to_piece@{step}: {e}")))?;
                out.push_str(&String::from_utf8_lossy(&bytes));
                // Stop if model dumps a new turn marker.
                if out.contains("<|turn>") || out.contains("<turn|>") {
                    if let Some(cut) = out.find("<|turn>").or_else(|| out.find("<turn|>")) {
                        out.truncate(cut);
                    }
                    break;
                }
                batch.clear();
                batch
                    .add(token, n_cur, &[0], true)
                    .map_err(|e| Error::Cleanup(format!("batch.add gen@{step}: {e}")))?;
                lctx.decode(&mut batch)
                    .map_err(|e| Error::Cleanup(format!("decode gen@{step}: {e}")))?;
                n_cur += 1;
            }
            Ok(out)
        }
    }

    /// Gemma 4 IT turn protocol (no `<|think|>`).
    fn format_gemma4_prompt(system: &str, user: &str) -> String {
        format!(
            "<|turn>system\n{}\n<turn|>\n<|turn>user\n{}\n<turn|>\n<|turn>model\n",
            system.trim(),
            user.trim()
        )
    }

    fn truncate_chars(s: &str, max: usize) -> String {
        if s.chars().count() <= max {
            return s.to_string();
        }
        s.chars().take(max).collect::<String>() + "…"
    }
}
