use local_flow_core::cleanup::{accepts_cleanup, heuristic_polish, smart_format, CleanupEngine};
use local_flow_core::context::DictationContext;
use local_flow_core::personalization::{
    apply_context, apply_replacements, expand_snippets, Personalization, Replacement, Snippet,
};
use local_flow_core::session::Engine;

#[test]
fn kot_to_kod_in_tech_chat() {
    let ctx = DictationContext {
        channel_hint: "Thread ds-team".into(),
        chat_lines: vec!["надо поправить сервис".into()],
        ..Default::default()
    };
    let out = heuristic_polish("Да больше не пишем кот.", &ctx);
    assert!(out.to_lowercase().contains("код"), "got {out}");
    assert!(!out.to_lowercase().contains("кот"));
}

#[test]
fn gazovogo_voda_to_golosovogo_vvoda() {
    let ctx = DictationContext {
        app_name: "Cursor".into(),
        bundle_id: "com.todesktop.230313mzl4w4u92".into(),
        ..Default::default()
    };
    assert!(ctx.is_editor());
    let out = heuristic_polish("Газового вода", &ctx);
    let low = out.to_lowercase();
    assert!(low.contains("голосового ввода"), "got {out}");
    assert!(!low.contains("газового"), "got {out}");
    assert!(
        !low.split_whitespace()
            .any(|w| w.trim_matches(|c: char| !c.is_alphabetic()) == "вода"),
        "got {out}"
    );
}

#[test]
fn engine_session_fsm_smoke() {
    let eng = Engine::with_defaults();
    let summary = eng.load_models().unwrap();
    // stub/heuristic if models missing; whisper/qwen3 when downloaded
    assert!(
        summary.contains("heuristic")
            || summary.contains("stub")
            || summary.contains("whisper")
            || summary.contains("qwen")
    );
    eng.start_hold().unwrap();
    // tiny silence — below min duration → empty
    eng.push_audio(&[0.0; 100]).unwrap();
    let r = eng.end_hold(DictationContext::default()).unwrap();
    assert!(r.clean.is_empty());
}

#[test]
fn cleanup_engine_heuristic() {
    let c = CleanupEngine::heuristic();
    let ctx = DictationContext {
        channel_hint: "devops".into(),
        ..Default::default()
    };
    let out = c.cleanup("ну типа привет кот", &ctx).unwrap();
    assert!(out.to_lowercase().contains("код") || out.to_lowercase().contains("привет"));
}

#[test]
#[cfg(feature = "llama")]
fn qwen_cleanup_smoke_if_present() {
    use local_flow_core::cleanup::CleanupEngine;
    use local_flow_core::config::EngineConfig;
    let cfg = EngineConfig::default();
    if !cfg.llm_model.exists() {
        return;
    }
    let eng = CleanupEngine::load(&cfg.llm_model, &cfg.cleanup_prompt).expect("load qwen");
    let ctx = DictationContext {
        channel_hint: "Thread ds-team".into(),
        chat_lines: vec!["надо поправить сервис".into()],
        ..Default::default()
    };
    let out = eng
        .cleanup("Да больше не пишем кот.", &ctx)
        .expect("cleanup");
    eprintln!("qwen out: {out}");
    assert!(!out.is_empty());
    assert!(out.to_lowercase().contains("код") || out.to_lowercase().contains("не пиш"));
}

#[test]
fn local_dictionary_and_snippets_are_applied() {
    let settings = Personalization {
        dictionary: vec![Replacement {
            heard: "кубинетес".into(),
            replace_with: "Kubernetes".into(),
        }],
        snippets: vec![Snippet {
            trigger: "мой линк".into(),
            expansion: "https://example.test".into(),
        }],
        ..Default::default()
    };
    let mut ctx = DictationContext {
        bundle_id: "com.todesktop.230313mzl4w4u92".into(),
        ..Default::default()
    };
    apply_context(&mut ctx, &settings);
    assert!(ctx.custom_vocabulary.contains(&"Kubernetes".into()));
    let corrected = apply_replacements("проверь кубинетес", &settings);
    assert!(corrected.contains("Kubernetes"));
    let expanded = expand_snippets("открой мой линк.", &settings);
    assert!(expanded.contains("https://example.test"), "got {expanded}");
}

#[test]
fn smart_formatting_commands_and_backtrack() {
    let cases = [
        (
            "Привет запятая мир новая строка как дела вопросительный знак",
            "Привет, мир\nкак дела?",
            false,
        ),
        (
            "Первое проверить сборку второе отправить PR",
            "1. проверить сборку\n2. отправить PR",
            false,
        ),
        ("Встреча в 2, нет, в 3", "Встреча в 3", false),
        ("Я вообще-то дома", "Я вообще-то дома", false),
        ("Отправь отчёт нажми enter.", "Отправь отчёт", true),
        ("Нажми enter", "", true),
    ];
    for (input, expected, enter) in cases {
        let actual = smart_format(input);
        assert_eq!(actual.text, expected, "input: {input}");
        assert_eq!(actual.press_enter, enter, "input: {input}");
    }
}

#[test]
fn asr_prompt_contains_evidence_not_canned_dictation_phrases() {
    let ctx = DictationContext {
        app_name: "Cursor".into(),
        channel_hint: "worker.rs".into(),
        before_text: "let Kubernetes".into(),
        custom_vocabulary: vec!["Kubernetes".into(), "LangFuse".into()],
        ..Default::default()
    };
    let prompt = ctx.asr_initial_prompt().expect("evidence prompt");
    assert!(prompt.contains("Kubernetes"));
    assert!(prompt.contains("worker.rs"));
    assert!(!prompt.to_lowercase().contains("голосовой ввод"));
    assert!(!prompt.to_lowercase().contains("проверка"));
}

#[test]
fn cleanup_guard_rejects_semantic_collapse() {
    let ctx = DictationContext::default();
    assert!(!accepts_cleanup("велосипедового вода", "ввода", &ctx));
    assert!(!accepts_cleanup(
        "нужно проверить велосипедового вода перед релизом",
        "ввода",
        &ctx
    ));
}

#[test]
fn cleanup_guard_accepts_unambiguous_dictionary_style_correction() {
    let ctx = DictationContext {
        app_name: "Cursor".into(),
        bundle_id: "com.todesktop.230313mzl4w4u92".into(),
        ..Default::default()
    };
    assert!(accepts_cleanup(
        "проверка газового вода в курсоре",
        "Проверка голосового ввода в Cursor.",
        &ctx
    ));
}
