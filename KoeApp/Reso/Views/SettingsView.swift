import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Gemini", systemImage: "sparkle") {
                AsrSettingsTab()
            }
            Tab("Controls", systemImage: "keyboard") {
                HotkeySettingsTab()
            }
            Tab("Dictionary", systemImage: "text.book.closed") {
                DictionarySettingsTab()
            }
            Tab("Prompt", systemImage: "text.bubble") {
                PromptSettingsTab()
            }
        }
        .frame(width: 500, height: 380)
    }
}

// MARK: - ASR Settings

private struct AsrSettingsTab: View {
    @State private var apiKey = ""
    @State private var model = ""
    @State private var showKey = false

    var body: some View {
        Form {
            Section {
                Text("Configure Gemini Live API for speech recognition.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("API Key") {
                HStack {
                    if showKey {
                        TextField("API Key", text: $apiKey)
                    } else {
                        SecureField("API Key", text: $apiKey)
                    }
                    Button(showKey ? "Hide" : "Show") {
                        showKey.toggle()
                    }
                    .buttonStyle(.borderless)
                }
            }

            Section("Model") {
                TextField("Model", text: $model)
            }

            HStack {
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { load() }
    }

    private func load() {
        let yaml = readConfig()
        apiKey = yamlRead(yaml, key: "api_key")
        model = yamlRead(yaml, key: "model").isEmpty ? "gemini-3.1-flash-live-preview" : yamlRead(yaml, key: "model")
    }

    private func save() {
        var yaml = readConfig()
        yaml = yamlWrite(yaml, key: "api_key", value: apiKey)
        yaml = yamlWrite(yaml, key: "model", value: model)
        writeConfig(yaml)
        RustBridge.shared.reloadConfig()
    }
}

// MARK: - Hotkey Settings

private struct HotkeySettingsTab: View {
    @State private var triggerKey = "fn"
    @State private var cancelKey = "left_option"
    @State private var hideMenuIcon = false
    @State private var errorMessage: String?

    private let keyOptions = [
        ("fn", "Fn"),
        ("left_option", "Left Option"),
        ("right_option", "Right Option"),
        ("left_command", "Left Command"),
        ("right_command", "Right Command"),
    ]

    var body: some View {
        Form {
            Section {
                Text("Choose trigger and cancel keys for voice input.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Keys") {
                Picker("Trigger Key", selection: $triggerKey) {
                    ForEach(keyOptions, id: \.0) { key, label in
                        Text(label).tag(key)
                    }
                }
                Picker("Cancel Key", selection: $cancelKey) {
                    ForEach(keyOptions, id: \.0) { key, label in
                        Text(label).tag(key)
                    }
                }
            }

            Section("Appearance") {
                Toggle("Hide menu bar icon (show Dock icon instead)", isOn: $hideMenuIcon)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { load() }
    }

    private func load() {
        let yaml = readConfig()
        triggerKey = yamlRead(yaml, key: "trigger_key").isEmpty ? "fn" : yamlRead(yaml, key: "trigger_key")
        cancelKey = yamlRead(yaml, key: "cancel_key").isEmpty ? "left_option" : yamlRead(yaml, key: "cancel_key")
        hideMenuIcon = yamlRead(yaml, key: "hide_menu_icon") == "true"
    }

    private func save() {
        guard triggerKey != cancelKey else {
            errorMessage = "Trigger and cancel keys must be different."
            return
        }
        errorMessage = nil

        var yaml = readConfig()
        yaml = yamlWrite(yaml, key: "trigger_key", value: triggerKey)
        yaml = yamlWrite(yaml, key: "cancel_key", value: cancelKey)
        yaml = yamlWrite(yaml, key: "hide_menu_icon", value: hideMenuIcon ? "true" : "false")
        writeConfig(yaml)
        RustBridge.shared.reloadConfig()
    }
}

// MARK: - Dictionary Settings

private struct DictionarySettingsTab: View {
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("User dictionary — one term per line. These terms help improve recognition accuracy.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 12)

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal)

            HStack {
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .padding()
            }
        }
        .onAppear { load() }
    }

    private func load() {
        let path = NSHomeDirectory() + "/.koe/dictionary.txt"
        text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    private func save() {
        let path = NSHomeDirectory() + "/.koe/dictionary.txt"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - System Prompt Settings

private struct PromptSettingsTab: View {
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("System prompt sent to Gemini for speech recognition and correction.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 12)

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal)

            HStack {
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .padding()
            }
        }
        .onAppear { load() }
    }

    private func load() {
        let path = NSHomeDirectory() + "/.koe/system_prompt.txt"
        text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    private func save() {
        let path = NSHomeDirectory() + "/.koe/system_prompt.txt"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        RustBridge.shared.reloadConfig()
    }
}

// MARK: - YAML Helpers

private func configPath() -> String {
    NSHomeDirectory() + "/.koe/config.yaml"
}

private func readConfig() -> String {
    (try? String(contentsOfFile: configPath(), encoding: .utf8)) ?? ""
}

private func writeConfig(_ yaml: String) {
    try? yaml.write(toFile: configPath(), atomically: true, encoding: .utf8)
}

private func yamlRead(_ yaml: String, key: String) -> String {
    for line in yaml.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\(key):") {
            let value = trimmed.dropFirst("\(key):".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value
        }
    }
    return ""
}

private func yamlWrite(_ yaml: String, key: String, value: String) -> String {
    let lines = yaml.components(separatedBy: "\n")
    var result: [String] = []
    var replaced = false
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !replaced && trimmed.hasPrefix("\(key):") {
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
            let needsQuotes = value.contains(" ") || value.contains("#") || value.contains("$")
            let formatted = needsQuotes ? "\"\(value)\"" : value
            result.append("\(indent)\(key): \(formatted)")
            replaced = true
        } else {
            result.append(line)
        }
    }
    return result.joined(separator: "\n")
}
