use local_flow_core::cleanup::{
    accepts_cleanup, apply_common_asr_fixes, heuristic_polish, smart_format, CleanupEngine,
};
use local_flow_core::config::EngineConfig;
use local_flow_core::context::DictationContext;
use local_flow_core::personalization::{
    apply_context, apply_replacements, expand_snippets, Personalization, Replacement, Snippet,
};
use local_flow_core::session::Engine;

#[test]
fn common_asr_fixes_qwen_cursor_vvod() {
    let out = apply_common_asr_fixes(
        "а проверка голосового вода в курсуаре пытаюсье чтобы гвен нормальный текст выдал с точками запятыми",
    );
    assert!(out.contains("голосового ввода"), "{out}");
    assert!(out.contains("Cursor"), "{out}");
    assert!(out.contains("Qwen"), "{out}");
    assert!(out.contains("пытаюсь"), "{out}");
    assert!(!out.contains("гвен"), "{out}");
}

#[test]
fn heuristic_strips_fillers() {
    let out = heuristic_polish("ну типа привет мир", &DictationContext::default());
    let low = out.to_lowercase();
    assert!(low.contains("привет"), "got {out}");
    assert!(!low.contains("ну типа"), "got {out}");
}

#[test]
fn engine_session_fsm_smoke() {
    let data = tempfile::tempdir().unwrap();
    let eng = Engine::new(EngineConfig::new(data.path()));
    let summary = eng.load_models().unwrap();
    // stub/heuristic if models missing; whisper/gemma4 when downloaded
    assert!(
        summary.contains("heuristic")
            || summary.contains("stub")
            || summary.contains("whisper")
            || summary.contains("gemma")
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
    let out = c
        .cleanup("ну типа привет мир", &DictationContext::default())
        .unwrap();
    assert!(out.to_lowercase().contains("привет"), "got {out}");
}

#[test]
#[cfg(feature = "llama")]
fn qwen_cleanup_smoke_if_present() {
    use local_flow_core::cleanup::CleanupEngine;
    let Some(data_dir) = std::env::var_os("LOCAL_FLOW_DATA_DIR") else {
        return;
    };
    let cfg = EngineConfig::new(data_dir);
    if !cfg.llm_model.exists() {
        return;
    }
    let eng = CleanupEngine::load(&cfg.llm_model, &cfg.cleanup_prompt).expect("load qwen");
    let ctx = DictationContext {
        channel_hint: "Thread engineering".into(),
        chat_lines: vec!["надо поправить сервис".into()],
        ..Default::default()
    };
    let out = eng
        .cleanup("Да больше не пишем код.", &ctx)
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
        recent: vec!["деплой LangFuse на staging".into()],
        ..Default::default()
    };
    let prompt = ctx.asr_initial_prompt().expect("evidence prompt");
    assert!(prompt.contains("Kubernetes"));
    assert!(prompt.contains("worker.rs"));
    assert!(prompt.contains("LangFuse") || prompt.contains("staging"));
    assert!(!prompt.to_lowercase().contains("голосовой ввод"));
    assert!(!prompt.to_lowercase().contains("проверка"));
}

#[test]
fn dictionary_feeds_both_heard_and_replace_into_vocab() {
    let settings = Personalization {
        dictionary: vec![Replacement {
            heard: "кубинетес".into(),
            replace_with: "Kubernetes".into(),
        }],
        ..Default::default()
    };
    let mut ctx = DictationContext::default();
    apply_context(&mut ctx, &settings);
    assert!(ctx.custom_vocabulary.contains(&"Kubernetes".into()));
    assert!(ctx.custom_vocabulary.contains(&"кубинетес".into()));
    let prompt = ctx.asr_initial_prompt().expect("vocab prompt");
    assert!(prompt.contains("Kubernetes"));
    assert!(prompt.contains("кубинетес"));
}

#[test]
fn hub_snapshot_after_record_and_personalization_roundtrip() {
    let data = tempfile::tempdir().unwrap();
    let eng = Engine::new(EngineConfig::new(data.path()));
    let mut settings = eng.personalization();
    settings.dictionary.push(Replacement {
        heard: "гвен".into(),
        replace_with: "Gemma".into(),
    });
    eng.save_personalization(&settings).unwrap();
    local_flow_core::hub::record_dictation(
        data.path(),
        "сырой",
        "привет Gemma",
        "com.test.app",
        local_flow_core::DictationDestination::Field,
    )
    .unwrap();
    let snap = eng.hub_snapshot_json().unwrap();
    assert!(snap.contains("привет Gemma") || snap.contains("words_today"));
    let loaded = eng.personalization();
    assert_eq!(loaded.dictionary.len(), 1);
    assert_eq!(loaded.dictionary[0].replace_with, "Gemma");
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
    // Real paste.log: Qwen chopped the opening ("я хочу проверить…") and kept the tail.
    assert!(!accepts_cleanup(
        "я хочу проверить свой ввод поэтому я надектовываю текст вот хочу чтобы текст почистился после ковьяна вот я немного приболел поэтому голосу на немного другой вот так проверяем теперь как ведётся текст",
        "вот текст почистился после ковьяна вот я немного приболел поэтому голосу на немного другой вот так проверяем теперь как ведётся текст",
        &ctx
    ));
}

#[test]
fn cleanup_guard_accepts_light_polish() {
    let ctx = DictationContext {
        app_name: "Cursor".into(),
        bundle_id: "com.todesktop.230313mzl4w4u92".into(),
        ..Default::default()
    };
    assert!(accepts_cleanup(
        "проверка голосового ввода в курсоре",
        "Проверка голосового ввода в Cursor.",
        &ctx
    ));
}

#[test]
fn cleanup_guard_accepts_heavy_asr_repair() {
    let ctx = DictationContext {
        app_name: "Cursor".into(),
        bundle_id: "com.todesktop.230313mzl4w4u92".into(),
        ..Default::default()
    };
    // Real dirty Whisper → what Gemma should be allowed to keep.
    assert!(accepts_cleanup(
        "а проверка голосового вода в курсуаре пытаюсье чтобы гвен нормальный текст выдал с точками запятыми",
        "А проверка голосового ввода в Cursor. Пытаюсь, чтобы Qwen нормальный текст выдал с точками и запятыми.",
        &ctx
    ));
}

#[test]
fn cleanup_guard_rejects_context_hallucination() {
    let ctx = DictationContext::default();
    // Short dictation + long prose stolen from editor/chat context.
    assert!(!accepts_cleanup(
        "привет как дела",
        "Привет, как дела? Давай завтра созвонимся по поводу релиза сервиса и поправим баг в worker.rs после ревью.",
        &ctx
    ));
}
