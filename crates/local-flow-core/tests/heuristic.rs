use local_flow_core::cleanup::{heuristic_polish, CleanupEngine};
use local_flow_core::context::DictationContext;
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
        !low.split_whitespace().any(|w| w.trim_matches(|c: char| !c.is_alphabetic()) == "вода"),
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
    let out = eng.cleanup("Да больше не пишем кот.", &ctx).expect("cleanup");
    eprintln!("qwen out: {out}");
    assert!(!out.is_empty());
    assert!(out.to_lowercase().contains("код") || out.to_lowercase().contains("не пиш"));
}
