use koe_asr::{AsrConfig, AsrEvent, GeminiLiveProvider, TranscriptAggregator};

#[test]
fn test_default_config() {
    let config = AsrConfig::default();
    assert_eq!(config.sample_rate_hz, 16000);
    assert_eq!(config.connect_timeout_ms, 5000);
    assert_eq!(config.final_wait_timeout_ms, 10000);
    assert_eq!(config.model, "gemini-3.1-flash-live-preview");
}

#[test]
fn test_custom_config() {
    let config = AsrConfig {
        api_key: "test-key".into(),
        model: "gemini-2.5-flash".into(),
        ..Default::default()
    };
    assert_eq!(config.api_key, "test-key");
    assert_eq!(config.model, "gemini-2.5-flash");
}

#[test]
fn test_provider_creation() {
    let _provider = GeminiLiveProvider::new();
}

#[test]
fn test_transcript_aggregator_interim() {
    let mut agg = TranscriptAggregator::new();
    assert!(!agg.has_any_text());
    assert!(!agg.has_final_result());

    agg.update_interim("hello");
    assert!(agg.has_any_text());
    assert_eq!(agg.best_text(), "hello");

    agg.update_interim("hello world");
    assert_eq!(agg.best_text(), "hello world");
}

#[test]
fn test_transcript_aggregator_definite_overrides_interim() {
    let mut agg = TranscriptAggregator::new();
    agg.update_interim("interim text");
    agg.update_definite("definite text");
    assert_eq!(agg.best_text(), "definite text");
}

#[test]
fn test_transcript_aggregator_final_overrides_all() {
    let mut agg = TranscriptAggregator::new();
    agg.update_interim("interim");
    agg.update_definite("definite");
    agg.update_final("final result");
    assert!(agg.has_final_result());
    assert_eq!(agg.best_text(), "final result");
}

#[test]
fn test_asr_event_variants() {
    let events = vec![
        AsrEvent::Connected,
        AsrEvent::Interim("partial".into()),
        AsrEvent::Definite("confirmed".into()),
        AsrEvent::Final("done".into()),
        AsrEvent::Error("oops".into()),
        AsrEvent::Closed,
    ];
    for event in &events {
        let _ = format!("{:?}", event);
    }
    assert_eq!(events.len(), 6);
}
