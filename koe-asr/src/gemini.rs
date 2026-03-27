use crate::config::AsrConfig;
use crate::error::{AsrError, Result};
use crate::event::AsrEvent;
use crate::provider::AsrProvider;

use base64::Engine;
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::time::{timeout, Duration};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{connect_async, MaybeTlsStream, WebSocketStream};

type WsStream = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

const GEMINI_WS_BASE: &str = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent";
const AUDIO_MIME_TYPE: &str = "audio/pcm;rate=16000";
const AUDIO_STREAM_END_MSG: &str = r#"{"realtimeInput":{"audioStreamEnd":true}}"#;

/// Gemini Live API streaming provider.
///
/// Uses the Gemini Live WebSocket API with `responseModalities: ["AUDIO"]`
/// plus `outputAudioTranscription` to combine ASR + LLM correction in one step.
/// Audio is streamed as base64-encoded PCM; the model's spoken response is
/// captured via output transcription as text (audio data is discarded).
pub struct GeminiLiveProvider {
    ws: Option<WsStream>,
    accumulated_text: String,
}

impl GeminiLiveProvider {
    pub fn new() -> Self {
        Self {
            ws: None,
            accumulated_text: String::new(),
        }
    }

    fn ws_mut(&mut self) -> Result<&mut WsStream> {
        self.ws
            .as_mut()
            .ok_or_else(|| AsrError::Connection("not connected".into()))
    }

    async fn send_text(&mut self, text: String) -> Result<()> {
        let ws = self.ws_mut()?;
        ws.send(Message::Text(text.into()))
            .await
            .map_err(|e| AsrError::Protocol(format!("ws send: {e}")))
    }

    /// Parse a JSON message from the server. Returns `Some(Ok/Err)` for actionable
    /// events, `None` to skip and read the next message.
    fn parse_message(&mut self, text: &str) -> Option<Result<AsrEvent>> {
        let json: Value = match serde_json::from_str(text) {
            Ok(v) => v,
            Err(e) => return Some(Err(AsrError::Protocol(format!("parse response: {e}")))),
        };

        if let Some(sc) = json.get("serverContent") {
            if let Some(input_tx) = sc.get("inputTranscription") {
                if let Some(t) = input_tx.get("text").and_then(|v| v.as_str()) {
                    if !t.is_empty() {
                        return Some(Ok(AsrEvent::Interim(t.to_string())));
                    }
                }
            }

            if let Some(output_tx) = sc.get("outputTranscription") {
                if let Some(t) = output_tx.get("text").and_then(|v| v.as_str()) {
                    if !t.is_empty() {
                        self.accumulated_text.push_str(t);
                        return Some(Ok(AsrEvent::Interim(self.accumulated_text.clone())));
                    }
                }
            }

            if let Some(model_turn) = sc.get("modelTurn") {
                if let Some(parts) = model_turn.get("parts").and_then(|p| p.as_array()) {
                    for part in parts {
                        if part.get("inlineData").is_some() {
                            continue;
                        }
                        if let Some(t) = part.get("text").and_then(|v| v.as_str()) {
                            self.accumulated_text.push_str(t);
                        }
                    }
                }
                return None; // wait for turnComplete or transcription
            }

            if sc.get("turnComplete").and_then(|v| v.as_bool()).unwrap_or(false) {
                let final_text = std::mem::take(&mut self.accumulated_text);
                if !final_text.is_empty() {
                    return Some(Ok(AsrEvent::Final(final_text)));
                }
                return Some(Ok(AsrEvent::Closed));
            }

            return None;
        }

        if let Some(error) = json.get("error") {
            let msg = error.get("message").and_then(|m| m.as_str()).unwrap_or("unknown error");
            return Some(Ok(AsrEvent::Error(msg.to_string())));
        }

        None
    }
}

impl Default for GeminiLiveProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl AsrProvider for GeminiLiveProvider {
    async fn connect(&mut self, config: &AsrConfig) -> Result<()> {
        let connect_timeout = Duration::from_millis(config.connect_timeout_ms);

        let url = format!("{}?key={}", GEMINI_WS_BASE, config.gemini_api_key);
        let model = if config.gemini_model.starts_with("models/") {
            config.gemini_model.clone()
        } else {
            format!("models/{}", config.gemini_model)
        };

        log::info!("connecting to Gemini Live API: model={}", model);

        let (mut ws_stream, _response) = connect_async(&url)
            .await
            .map_err(|e| AsrError::Connection(e.to_string()))?;

        let mut setup_inner = json!({
            "model": model,
            "generationConfig": {
                "responseModalities": ["AUDIO"]
            },
            "inputAudioTranscription": {},
            "outputAudioTranscription": {}
        });

        if !config.system_prompt.is_empty() {
            setup_inner["systemInstruction"] = json!({
                "parts": [{"text": config.system_prompt}]
            });
        }

        let setup = json!({ "setup": setup_inner });

        let setup_str = serde_json::to_string(&setup)
            .map_err(|e| AsrError::Protocol(format!("serialize setup: {e}")))?;

        ws_stream
            .send(Message::Text(setup_str.into()))
            .await
            .map_err(|e| AsrError::Connection(format!("send setup: {e}")))?;

        // Wait for setupComplete, skip Ping/Pong frames
        let deadline = tokio::time::Instant::now() + connect_timeout;
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                return Err(AsrError::Connection("setup timed out".into()));
            }
            let resp = timeout(remaining, ws_stream.next())
                .await
                .map_err(|_| AsrError::Connection("setup timed out".into()))?
                .ok_or_else(|| AsrError::Connection("closed before setup".into()))?
                .map_err(|e| AsrError::Connection(format!("setup recv error: {e}")))?;

            let text_data = match resp {
                Message::Text(t) => t.into(),
                Message::Binary(b) => match String::from_utf8(b) {
                    Ok(s) => s,
                    Err(_) => continue,
                },
                Message::Close(frame) => {
                    let reason = frame
                        .map(|f| format!("{}: {}", f.code, f.reason))
                        .unwrap_or_else(|| "unknown".into());
                    return Err(AsrError::Connection(format!(
                        "closed during setup: {reason}"
                    )));
                }
                _ => continue,
            };

            if let Ok(json) = serde_json::from_str::<Value>(&text_data) {
                if json.get("setupComplete").is_some() {
                    log::info!("Gemini Live setup complete");
                    break;
                } else if let Some(err) = json.get("error") {
                    let msg = err
                        .get("message")
                        .and_then(|m| m.as_str())
                        .unwrap_or("unknown");
                    return Err(AsrError::Connection(format!("setup rejected: {msg}")));
                }
            }
        }

        self.ws = Some(ws_stream);
        log::info!("Gemini Live connected and ready");
        Ok(())
    }

    async fn send_audio(&mut self, frame: &[u8]) -> Result<()> {
        let b64 = base64::engine::general_purpose::STANDARD.encode(frame);
        let msg_str = format!(
            r#"{{"realtimeInput":{{"audio":{{"data":"{b64}","mimeType":"{AUDIO_MIME_TYPE}"}}}}}}"#,
        );
        self.send_text(msg_str).await
    }

    async fn finish_input(&mut self) -> Result<()> {
        self.send_text(AUDIO_STREAM_END_MSG.to_string()).await?;
        log::debug!("Gemini Live audioStreamEnd sent");
        Ok(())
    }

    async fn next_event(&mut self) -> Result<AsrEvent> {
        loop {
            let ws = match self.ws.as_mut() {
                Some(ws) => ws,
                None => return Err(AsrError::Connection("not connected".into())),
            };

            let text_str = match ws.next().await {
                Some(Ok(Message::Text(t))) => String::from(t),
                Some(Ok(Message::Binary(b))) => match String::from_utf8(b) {
                    Ok(s) => s,
                    Err(_) => continue,
                },
                Some(Ok(Message::Close(_))) => return Ok(AsrEvent::Closed),
                Some(Ok(_)) => continue,
                Some(Err(e)) => return Err(AsrError::Protocol(e.to_string())),
                None => return Ok(AsrEvent::Closed),
            };
            // ws borrow ends here, safe to call self.parse_message

            match self.parse_message(&text_str) {
                Some(event) => return event,
                None => continue,
            }
        }
    }

    async fn close(&mut self) -> Result<()> {
        self.accumulated_text.clear();
        if let Some(mut ws) = self.ws.take() {
            let _ = ws.close(None).await;
        }
        log::debug!("Gemini Live connection closed");
        Ok(())
    }
}
