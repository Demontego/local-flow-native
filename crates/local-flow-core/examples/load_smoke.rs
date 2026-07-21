use local_flow_core::{AsrEngine, CleanupEngine, Engine, EngineConfig};

fn main() {
    let data_dir = std::env::args_os()
        .nth(1)
        .expect("usage: cargo run --example load_smoke -- <application-data-dir>");
    let cfg = EngineConfig::new(data_dir);
    let eng = Engine::new(cfg.clone());
    let st = eng.models_status();
    println!("whisper_ready={} path={}", st.whisper, st.whisper_path);
    println!("llm_ready={} path={}", st.llm, st.llm_path);
    println!("load_models => {}", eng.load_models().unwrap());
    println!("load_models again => {}", eng.load_models().unwrap());

    match CleanupEngine::load(&cfg.llm_model, &cfg.cleanup_prompt) {
        Ok(c) => println!("direct cleanup={}", c.backend_name),
        Err(e) => println!("direct cleanup_err={e}"),
    }
    let _ = AsrEngine::load(&cfg.resolve_whisper_path());
}
