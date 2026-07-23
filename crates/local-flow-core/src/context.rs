use serde::{Deserialize, Serialize};

/// Platform shells fill this; core uses it for ASR prompt + cleanup.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DictationContext {
    pub app_name: String,
    pub bundle_id: String,
    pub channel_hint: String,
    pub before_text: String,
    pub selected_text: String,
    pub chat_lines: Vec<String>,
    pub recent: Vec<String>,
    pub screenshot_path: Option<String>,
    #[serde(default)]
    pub custom_vocabulary: Vec<String>,
    #[serde(default)]
    pub writing_style: String,
}

impl DictationContext {
    pub fn is_messenger(&self) -> bool {
        let blob = format!("{} {}", self.app_name, self.bundle_id).to_lowercase();
        [
            "telegram",
            "slack",
            "discord",
            "whatsapp",
            "messages",
            "messenger",
            "mattermost",
            "teams",
            "element",
            "signal",
        ]
        .iter()
        .any(|h| blob.contains(h))
    }

    pub fn is_editor(&self) -> bool {
        let blob =
            format!("{} {} {}", self.app_name, self.bundle_id, self.channel_hint).to_lowercase();
        [
            "cursor",
            "todesktop",
            "vscode",
            "xcode",
            "sublime",
            "zed",
            "windsurf",
        ]
        .iter()
        .any(|h| blob.contains(h))
    }

    pub fn is_tech_chat(&self) -> bool {
        if self.is_editor() {
            return true;
        }
        let blob = format!(
            "{} {} {} {} {}",
            self.app_name,
            self.bundle_id,
            self.channel_hint,
            self.before_text,
            self.chat_lines.join(" ")
        )
        .to_lowercase();
        [
            "devops",
            "engineering",
            "code",
            "deploy",
            "сервис",
            "код",
            "pr",
            "gitlab",
            "github",
            "thread",
        ]
        .iter()
        .any(|h| blob.contains(h))
    }

    /// Full context dump — for debugging / shells. Not for LLM cleanup
    /// (chat/draft prose makes small models invent text).
    pub fn to_prompt_block(&self) -> String {
        self.to_cleanup_hint()
    }

    /// Minimal disambiguation for Gemma: app + tone only.
    /// Never include chat/draft/selection/recent — model copies that instead of ASR.
    pub fn to_cleanup_hint(&self) -> String {
        let kind = if self.is_messenger() {
            "messenger"
        } else if self.is_editor() {
            "code-editor"
        } else if self.is_tech_chat() {
            "tech-chat"
        } else {
            "other"
        };
        let app = if self.app_name.is_empty() {
            "unknown"
        } else {
            self.app_name.as_str()
        };
        let mut parts = vec![
            format!("App: {app} ({kind})"),
            "Context is ONLY for tone + fixing product-name ASR. Never copy, continue, or quote it."
                .into(),
        ];
        // Short title tokens only (file/channel name) — not message bodies.
        if !self.channel_hint.is_empty() {
            let title: String = self.channel_hint.chars().take(60).collect();
            parts.push(format!("Window title (vocab only): {title}"));
        }
        if !self.writing_style.is_empty() {
            parts.push(format!("Tone: {}", self.writing_style.chars().take(80).collect::<String>()));
        }
        if !self.custom_vocabulary.is_empty() {
            let vocab = self
                .custom_vocabulary
                .iter()
                .take(8)
                .cloned()
                .collect::<Vec<_>>()
                .join(", ");
            parts.push(format!("Vocab: {vocab}"));
        }
        parts.join("\n")
    }

    /// Keep Whisper's prompt to vocabulary and local context, never a canned phrase.
    pub fn asr_initial_prompt(&self) -> Option<String> {
        let mut bits: Vec<String> = Vec::new();
        if !self.custom_vocabulary.is_empty() {
            bits.push(
                self.custom_vocabulary
                    .iter()
                    .take(16)
                    .cloned()
                    .collect::<Vec<_>>()
                    .join(" "),
            );
        }
        if self.is_editor() {
            bits.push("код сервис коммит файл".into());
        } else if self.is_tech_chat() {
            bits.push("код сервис деплой логи коммит PR".into());
        }
        if !self.channel_hint.is_empty() {
            bits.push(self.channel_hint.chars().take(80).collect());
        }
        if !self.before_text.is_empty() {
            bits.push(self.before_text.trim().chars().take(80).collect());
        }
        let joined = bits.join(" ");
        (!joined.trim().is_empty()).then(|| joined.chars().take(160).collect())
    }
}
