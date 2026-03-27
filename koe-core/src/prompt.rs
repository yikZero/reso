use std::path::Path;

/// Load system prompt from file, or return built-in default.
/// cbindgen:ignore
pub fn load_system_prompt(path: &Path) -> String {
    match std::fs::read_to_string(path) {
        Ok(content) => {
            let trimmed = content.trim();
            if trimmed.is_empty() {
                log::warn!("system prompt file is empty, using built-in default");
                build_default_system_prompt()
            } else {
                log::info!("loaded system prompt from {}", path.display());
                trimmed.to_string()
            }
        }
        Err(e) => {
            log::warn!("failed to load system prompt from {}: {e}, using built-in default", path.display());
            build_default_system_prompt()
        }
    }
}

/// Built-in default system prompt.
/// cbindgen:ignore
fn build_default_system_prompt() -> String {
    include_str!("default_system_prompt.txt").trim().to_string()
}
