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
            "itsa-orcs",
            "time",
            "teams",
            "element",
            "signal",
        ]
        .iter()
        .any(|h| blob.contains(h))
    }

    pub fn is_editor(&self) -> bool {
        let blob = format!(
            "{} {} {}",
            self.app_name, self.bundle_id, self.channel_hint
        )
        .to_lowercase();
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
            "ds-team",
            "devops",
            "code",
            "deploy",
            "сервис",
            "код",
            "pr",
            "gitlab",
            "github",
            "claude",
            "messenger",
            "itsa-orcs",
            "thread",
        ]
        .iter()
        .any(|h| blob.contains(h))
    }

    pub fn to_prompt_block(&self) -> String {
        let kind = if self.is_messenger() {
            "messenger"
        } else if self.is_editor() {
            "code-editor"
        } else if self.is_tech_chat() {
            "tech-chat"
        } else {
            "other"
        };
        let mut parts = vec![
            format!(
                "Focused app: {} ({})",
                if self.app_name.is_empty() {
                    "unknown"
                } else {
                    &self.app_name
                },
                if self.bundle_id.is_empty() {
                    "—"
                } else {
                    &self.bundle_id
                }
            ),
            format!("Surface kind: {kind}"),
        ];
        if !self.channel_hint.is_empty() {
            parts.push(format!(
                "Window / channel / file title (use for topic + vocabulary): {}",
                self.channel_hint
            ));
        }
        if !self.before_text.is_empty() {
            parts.push(format!(
                "Text already in the focused field (before/around cursor): {:?}",
                self.before_text
            ));
        }
        if !self.selected_text.is_empty() {
            parts.push(format!("Selected text: {:?}", self.selected_text));
        }
        if !self.chat_lines.is_empty() {
            parts.push(
                "Visible UI / messages / editor context (names, topics, homophones):".into(),
            );
            for line in self.chat_lines.iter().rev().take(8).rev() {
                let short: String = line.chars().take(160).collect();
                parts.push(format!("- {short}"));
            }
        }
        if !self.recent.is_empty() {
            parts.push("Recent dictations in this app:".into());
            for line in self.recent.iter().rev().take(8).rev() {
                parts.push(format!("- {line}"));
            }
        }
        parts.push(
            "Adapt wording to this surface (casual chat vs code/editor vs docs). Keep spaces between words."
                .into(),
        );
        parts.join("\n")
    }

    /// Bias whisper `initial_prompt`. Keep short — chat UI dumps crowd out the bias.
    pub fn asr_initial_prompt(&self) -> Option<String> {
        let mut bits: Vec<String> = Vec::new();
        // First: high-value vocab (Whisper small RU: голосовой→газовый, ввод→вода).
        if self.is_editor() {
            bits.push(
                "Проверка голосового ввода в Cursor. Диктовка код коммит файл.".into(),
            );
        } else if self.is_tech_chat() {
            bits.push("Голосовой ввод. Код сервис деплой логи коммит PR.".into());
        } else {
            bits.push("Голосовой ввод диктовка проверка.".into());
        }
        if !self.channel_hint.is_empty() {
            bits.push(self.channel_hint.chars().take(80).collect());
        }
        if !self.before_text.is_empty() {
            bits.push(self.before_text.trim().chars().take(80).collect());
        }
        for r in self.recent.iter().rev().take(2).rev() {
            bits.push(r.chars().take(60).collect());
        }
        let joined = bits.join(" ");
        Some(joined.chars().take(220).collect())
    }
}
