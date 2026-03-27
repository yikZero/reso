use crate::errors::{KoeError, Result};
use serde::Deserialize;
use std::path::{Path, PathBuf};

/// Root configuration structure matching ~/.koe/config.yaml
#[derive(Debug, Deserialize, Clone)]
pub struct Config {
    #[serde(default)]
    pub asr: AsrSection,
    #[serde(default)]
    pub feedback: FeedbackSection,
    #[serde(default)]
    pub appearance: AppearanceSection,
    #[serde(default)]
    pub dictionary: DictionarySection,
    #[serde(default)]
    pub hotkey: HotkeySection,
}

// ─── ASR Configuration ──────────────────────────────────────────────

#[derive(Debug, Deserialize, Clone)]
pub struct AsrSection {
    #[serde(default)]
    pub api_key: String,
    #[serde(default = "default_gemini_model")]
    pub model: String,
    #[serde(default = "default_connect_timeout")]
    pub connect_timeout_ms: u64,
    #[serde(default = "default_final_wait_timeout")]
    pub final_wait_timeout_ms: u64,
    #[serde(default = "default_system_prompt_path")]
    pub system_prompt_path: String,
}

// ─── Other Sections ─────────────────────────────────────────────────

#[derive(Debug, Deserialize, Clone)]
pub struct FeedbackSection {
    #[serde(default = "default_true")]
    pub start_sound: bool,
    #[serde(default = "default_true")]
    pub stop_sound: bool,
    #[serde(default = "default_true")]
    pub error_sound: bool,
}

#[derive(Debug, Deserialize, Clone)]
pub struct AppearanceSection {
    #[serde(default)]
    pub hide_menu_icon: bool,
}

#[derive(Debug, Deserialize, Clone)]
pub struct DictionarySection {
    #[serde(default = "default_dictionary_path")]
    pub path: String,
}

#[derive(Debug, Deserialize, Clone)]
pub struct HotkeySection {
    /// Trigger key for voice input.
    /// Options: "fn", "left_option", "right_option", "left_command", "right_command"
    /// Default: "fn"
    #[serde(default = "default_trigger_key")]
    pub trigger_key: String,

    /// Cancel key for aborting the current voice input session.
    /// Options: "fn", "left_option", "right_option", "left_command", "right_command"
    /// Default: "left_option"
    #[serde(default = "default_cancel_key")]
    pub cancel_key: String,
}

/// Resolved hotkey parameters for the native side
#[derive(Debug, Clone, Copy)]
pub struct HotkeyParams {
    /// Primary key code (from Carbon Events)
    pub key_code: u16,
    /// Alternative key code (e.g. 179 for Globe key), 0 if none
    pub alt_key_code: u16,
    /// Modifier flag to check (e.g. NSEventModifierFlagFunction = 0x800000)
    pub modifier_flag: u64,
}

/// Resolved trigger/cancel hotkey parameters for the native side.
#[derive(Debug, Clone, Copy)]
pub struct ResolvedHotkeyConfig {
    pub trigger: HotkeyParams,
    pub cancel: HotkeyParams,
}

impl HotkeySection {
    pub fn normalized_keys(&self) -> (String, String) {
        let trigger_key = self.normalized_trigger_key();
        let cancel_key = self.normalized_cancel_key(&trigger_key);
        (trigger_key, cancel_key)
    }

    /// Resolve the configured trigger/cancel hotkeys into concrete key codes
    /// and modifier flags. If both hotkeys are configured to the same key,
    /// keep the trigger key and fall back the cancel key to a distinct default.
    pub fn resolve(&self) -> ResolvedHotkeyConfig {
        let (trigger_key, cancel_key) = self.normalized_keys();
        ResolvedHotkeyConfig {
            trigger: Self::resolve_key(&trigger_key),
            cancel: Self::resolve_key(&cancel_key),
        }
    }

    fn normalized_trigger_key(&self) -> String {
        Self::normalize_trigger_key_name(&self.trigger_key)
    }

    fn normalized_cancel_key(&self, trigger_key: &str) -> String {
        let cancel_key = Self::normalize_cancel_key_name(&self.cancel_key);
        if cancel_key == trigger_key {
            default_cancel_key_for_trigger(trigger_key).into()
        } else {
            cancel_key
        }
    }

    fn normalize_trigger_key_name(value: &str) -> String {
        match value {
            "left_option" | "right_option" | "left_command" | "right_command" | "fn" => value.into(),
            _ => default_trigger_key(),
        }
    }

    fn normalize_cancel_key_name(value: &str) -> String {
        match value {
            "left_option" | "right_option" | "left_command" | "right_command" | "fn" => value.into(),
            _ => default_cancel_key(),
        }
    }

    fn resolve_key(key: &str) -> HotkeyParams {
        match key {
            "left_option" => HotkeyParams {
                key_code: 58,       // kVK_Option
                alt_key_code: 0,
                modifier_flag: 0x00000020,  // NX_DEVICELALTKEYMASK
            },
            "right_option" => HotkeyParams {
                key_code: 61,       // kVK_RightOption
                alt_key_code: 0,
                modifier_flag: 0x00000040,  // NX_DEVICERALTKEYMASK
            },
            "left_command" => HotkeyParams {
                key_code: 55,       // kVK_Command
                alt_key_code: 0,
                modifier_flag: 0x00000008,  // NX_DEVICELCMDKEYMASK
            },
            "right_command" => HotkeyParams {
                key_code: 54,       // kVK_RightCommand
                alt_key_code: 0,
                modifier_flag: 0x00000010,  // NX_DEVICERCMDKEYMASK
            },
            // "fn" or anything else defaults to Fn/Globe
            _ => HotkeyParams {
                key_code: 63,       // kVK_Function (Fn)
                alt_key_code: 179,  // Globe key on newer keyboards
                modifier_flag: 0x00800000,  // NSEventModifierFlagFunction
            },
        }
    }
}

// ─── Defaults ───────────────────────────────────────────────────────

fn default_connect_timeout() -> u64 {
    5000
}
fn default_final_wait_timeout() -> u64 {
    10000
}
fn default_gemini_model() -> String {
    "gemini-3.1-flash-live-preview".into()
}
fn default_true() -> bool {
    true
}
fn default_dictionary_path() -> String {
    "dictionary.txt".into()
}
fn default_system_prompt_path() -> String {
    "system_prompt.txt".into()
}
fn default_trigger_key() -> String {
    "fn".into()
}

fn default_cancel_key() -> String {
    "left_option".into()
}

fn default_cancel_key_for_trigger(trigger_key: &str) -> &'static str {
    match trigger_key {
        "fn" => "left_option",
        "left_option" => "right_option",
        "right_option" => "left_command",
        "left_command" => "right_command",
        "right_command" => "fn",
        _ => "left_option",
    }
}

impl Default for Config {
    fn default() -> Self {
        serde_yaml::from_str("{}").unwrap()
    }
}
impl Default for AsrSection {
    fn default() -> Self {
        serde_yaml::from_str("{}").unwrap()
    }
}
impl Default for FeedbackSection {
    fn default() -> Self {
        serde_yaml::from_str("{}").unwrap()
    }
}
impl Default for AppearanceSection {
    fn default() -> Self {
        serde_yaml::from_str("{}").unwrap()
    }
}
impl Default for DictionarySection {
    fn default() -> Self {
        serde_yaml::from_str("{}").unwrap()
    }
}
impl Default for HotkeySection {
    fn default() -> Self {
        serde_yaml::from_str("{}").unwrap()
    }
}

// ─── Config Directory ───────────────────────────────────────────────

/// Returns ~/.koe/
pub fn config_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home).join(".koe")
}

/// Returns ~/.koe/config.yaml
pub fn config_path() -> PathBuf {
    config_dir().join("config.yaml")
}

/// Resolve a path relative to config dir.
fn resolve_path(p: &str) -> PathBuf {
    let path = Path::new(p);
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        config_dir().join(path)
    }
}

/// Resolve system prompt path (relative to config dir).
pub fn resolve_system_prompt_path(config: &Config) -> PathBuf {
    resolve_path(&config.asr.system_prompt_path)
}

// ─── Environment Variable Substitution ──────────────────────────────

/// Replace ${VAR_NAME} patterns with environment variable values.
fn substitute_env_vars(input: &str) -> String {
    let mut result = input.to_string();
    loop {
        let start = match result.find("${") {
            Some(pos) => pos,
            None => break,
        };
        let end = match result[start + 2..].find('}') {
            Some(pos) => start + 2 + pos,
            None => break,
        };
        let var_name = &result[start + 2..end];
        let value = std::env::var(var_name).unwrap_or_default();
        result = format!("{}{}{}", &result[..start], value, &result[end + 1..]);
    }
    result
}

// ─── Hotkey Config Normalization ────────────────────────────────────

/// Ensure hotkey config persisted on disk includes both trigger and cancel keys.
fn normalize_hotkey_config(path: &Path, config: &Config) -> Result<bool> {
    let raw = std::fs::read_to_string(path)
        .map_err(|e| KoeError::Config(format!("read {}: {e}", path.display())))?;

    let mut doc: serde_yaml::Value = serde_yaml::from_str(&raw)
        .map_err(|e| KoeError::Config(format!("parse {}: {e}", path.display())))?;

    let doc_map = match doc.as_mapping_mut() {
        Some(map) => map,
        None => return Ok(false),
    };

    let (normalized_trigger, normalized_cancel) = config.hotkey.normalized_keys();
    let hotkey_key = serde_yaml::Value::String("hotkey".into());

    let hotkey_value = doc_map.entry(hotkey_key).or_insert_with(|| {
        serde_yaml::Value::Mapping(serde_yaml::Mapping::new())
    });

    let hotkey_map = match hotkey_value.as_mapping_mut() {
        Some(map) => map,
        None => return Ok(false),
    };

    let trigger_key = serde_yaml::Value::String("trigger_key".into());
    let cancel_key = serde_yaml::Value::String("cancel_key".into());

    let stored_trigger = hotkey_map.get(&trigger_key).and_then(|v| v.as_str());
    let stored_cancel = hotkey_map.get(&cancel_key).and_then(|v| v.as_str());

    if stored_trigger == Some(normalized_trigger.as_str())
        && stored_cancel == Some(normalized_cancel.as_str())
    {
        return Ok(false);
    }

    hotkey_map.insert(trigger_key, serde_yaml::Value::String(normalized_trigger));
    hotkey_map.insert(cancel_key, serde_yaml::Value::String(normalized_cancel));

    let yaml_str = serde_yaml::to_string(&doc)
        .map_err(|e| KoeError::Config(format!("serialize normalized config: {e}")))?;

    let output = format!(
        "# Koe - Voice Input Tool Configuration\n\
         # ~/.koe/config.yaml\n\n\
         {yaml_str}"
    );

    std::fs::write(path, &output)
        .map_err(|e| KoeError::Config(format!("write normalized config {}: {e}", path.display())))?;

    log::info!("normalized hotkey config on disk");
    Ok(true)
}

// ─── Load & Ensure ─────────────────────────────────────────────────

/// Load config from ~/.koe/config.yaml.
/// Performs environment variable substitution before parsing.
pub fn load_config() -> Result<Config> {
    let path = config_path();

    if !path.exists() {
        return Err(KoeError::Config(format!(
            "config file not found: {}",
            path.display()
        )));
    }

    let raw = std::fs::read_to_string(&path)
        .map_err(|e| KoeError::Config(format!("read {}: {e}", path.display())))?;

    let substituted = substitute_env_vars(&raw);

    let config: Config = serde_yaml::from_str(&substituted)
        .map_err(|e| KoeError::Config(format!("parse {}: {e}", path.display())))?;

    match normalize_hotkey_config(&path, &config) {
        Ok(true) => log::info!("config file updated with normalized hotkey settings"),
        Ok(false) => {}
        Err(e) => log::warn!("hotkey config normalization failed: {e}"),
    }

    Ok(config)
}

/// Ensure ~/.koe/ exists with default config.yaml and dictionary.txt.
/// Returns true if files were created (first launch).
pub fn ensure_defaults() -> Result<bool> {
    let dir = config_dir();
    let config_file = config_path();
    let dict_file = dir.join("dictionary.txt");
    let system_prompt_file = dir.join("system_prompt.txt");

    let mut created = false;

    if !dir.exists() {
        std::fs::create_dir_all(&dir)
            .map_err(|e| KoeError::Config(format!("create {}: {e}", dir.display())))?;
        created = true;
    }

    let defaults: &[(&std::path::Path, &str)] = &[
        (&config_file, DEFAULT_CONFIG_YAML),
        (&dict_file, DEFAULT_DICTIONARY_TXT),
        (&system_prompt_file, DEFAULT_SYSTEM_PROMPT),
    ];

    for (path, content) in defaults {
        if !path.exists() {
            std::fs::write(path, content)
                .map_err(|e| KoeError::Config(format!("write {}: {e}", path.display())))?;
            log::info!("created default: {}", path.display());
            created = true;
        }
    }

    Ok(created)
}

const DEFAULT_CONFIG_YAML: &str = r#"# Koe - Voice Input Tool Configuration
# ~/.koe/config.yaml

asr:
  # Gemini Live API (combined ASR + LLM correction)
  api_key: ""          # Google AI API key, or use ${GEMINI_API_KEY}
  model: "gemini-3.1-flash-live-preview"
  connect_timeout_ms: 5000
  final_wait_timeout_ms: 10000
  system_prompt_path: "system_prompt.txt"  # relative to ~/.koe/

feedback:
  start_sound: false
  stop_sound: false
  error_sound: false

dictionary:
  path: "dictionary.txt"  # relative to ~/.koe/

hotkey:
  # 触发键：fn | left_option | right_option | left_command | right_command
  trigger_key: "fn"
  # 取消键：不能与触发键重复
  cancel_key: "left_option"
"#;

const DEFAULT_DICTIONARY_TXT: &str = r#"# Koe User Dictionary
# One term per line. These terms can be referenced in the system prompt.
# Lines starting with # are comments.

"#;

const DEFAULT_SYSTEM_PROMPT: &str = include_str!("default_system_prompt.txt");

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_config_path(name: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!("koe-{name}-{nonce}.yaml"))
    }

    #[test]
    fn normalize_hotkey_config_backfills_missing_cancel_key() {
        let path = temp_config_path("hotkey-config");
        fs::write(
            &path,
            "hotkey:\n  trigger_key: left_option\n",
        )
        .unwrap();

        let config = Config {
            hotkey: HotkeySection {
                trigger_key: "left_option".into(),
                cancel_key: "".into(),
            },
            ..Config::default()
        };

        let changed = normalize_hotkey_config(&path, &config).unwrap();
        let output = fs::read_to_string(&path).unwrap();

        assert!(changed);
        assert!(output.contains("trigger_key: left_option"));
        assert!(output.contains("cancel_key: right_option"));

        let _ = fs::remove_file(path);
    }
}
