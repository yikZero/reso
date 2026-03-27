/// Configuration for a Gemini Live ASR session.
#[derive(Debug, Clone)]
pub struct AsrConfig {
    /// Gemini API key
    pub api_key: String,
    /// Gemini model name (e.g. "gemini-3.1-flash-live-preview")
    pub model: String,
    /// System prompt for Gemini (used as systemInstruction)
    pub system_prompt: String,
    /// Audio sample rate in Hz (default: 16000)
    pub sample_rate_hz: u32,
    /// Connection timeout in milliseconds (default: 5000)
    pub connect_timeout_ms: u64,
    /// Timeout waiting for final result after finish signal (default: 10000)
    pub final_wait_timeout_ms: u64,
}

impl Default for AsrConfig {
    fn default() -> Self {
        Self {
            api_key: String::new(),
            model: "gemini-3.1-flash-live-preview".into(),
            system_prompt: String::new(),
            sample_rate_hz: 16000,
            connect_timeout_ms: 5000,
            final_wait_timeout_ms: 10000,
        }
    }
}
