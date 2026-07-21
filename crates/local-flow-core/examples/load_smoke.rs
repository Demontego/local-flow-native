use local_flow_core::{AsrEngine, CleanupEngine, Engine, EngineConfig};

fn main() {
    let eng = Engine::with_defaults();
    let st = eng.models_status();
    println!("whisper_ready={} path={}", st.whisper, st.whisper_path);
    println!("llm_ready={} path={}", st.llm, st.llm_path);
    println!("load_models => {}", eng.load_models().unwrap());
    println!("load_models again => {}", eng.load_models().unwrap());

    let cfg = EngineConfig::default();
    match CleanupEngine::load(&cfg.llm_model, &cfg.cleanup_prompt) {
        Ok(c) => println!("direct cleanup={}", c.backend_name),
        Err(e) => println!("direct cleanup_err={e}"),
    }
    let _ = AsrEngine::load(&cfg.resolve_whisper_path());
}
