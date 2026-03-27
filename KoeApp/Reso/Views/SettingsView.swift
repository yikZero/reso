import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            Tab("Gemini", systemImage: "sparkle") {
                AsrSettingsTab(appState: appState)
            }
            Tab("Controls", systemImage: "keyboard") {
                HotkeySettingsTab(appState: appState)
            }
            Tab("Dictionary", systemImage: "text.book.closed") {
                DictionarySettingsTab()
            }
            Tab("Prompt", systemImage: "text.bubble") {
                PromptSettingsTab(appState: appState)
            }
        }
        .frame(width: 500, height: 380)
    }
}

// MARK: - ASR Settings

private struct AsrSettingsTab: View {
    let appState: AppState
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
        let yaml = koeReadConfig()
        apiKey = koeYamlRead(yaml, key: "api_key")
        let m = koeYamlRead(yaml, key: "model")
        model = m.isEmpty ? "gemini-3.1-flash-live-preview" : m
    }

    private func save() {
        var yaml = koeReadConfig()
        yaml = koeYamlWrite(yaml, key: "api_key", value: apiKey)
        yaml = koeYamlWrite(yaml, key: "model", value: model)
        koeWriteConfig(yaml)
        appState.reloadConfig()
    }
}

// MARK: - Hotkey Settings

private struct HotkeySettingsTab: View {
    let appState: AppState
    @State private var triggerKey = "fn"
    @State private var cancelKey = "left_option"
    @State private var hideMenuIcon = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Text("Choose trigger and cancel keys for voice input.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Keys") {
                Picker("Trigger Key", selection: $triggerKey) {
                    ForEach(koeKeyOptions, id: \.key) { key, label in
                        Text(label).tag(key)
                    }
                }
                Picker("Cancel Key", selection: $cancelKey) {
                    ForEach(koeKeyOptions, id: \.key) { key, label in
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
        let yaml = koeReadConfig()
        let t = koeYamlRead(yaml, key: "trigger_key")
        triggerKey = t.isEmpty ? "fn" : t
        let c = koeYamlRead(yaml, key: "cancel_key")
        cancelKey = c.isEmpty ? "left_option" : c
        hideMenuIcon = koeYamlRead(yaml, key: "hide_menu_icon") == "true"
    }

    private func save() {
        guard triggerKey != cancelKey else {
            errorMessage = "Trigger and cancel keys must be different."
            return
        }
        errorMessage = nil

        var yaml = koeReadConfig()
        yaml = koeYamlWrite(yaml, key: "trigger_key", value: triggerKey)
        yaml = koeYamlWrite(yaml, key: "cancel_key", value: cancelKey)
        yaml = koeYamlWrite(yaml, key: "hide_menu_icon", value: hideMenuIcon ? "true" : "false")
        koeWriteConfig(yaml)
        appState.reloadConfig()
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
        text = (try? String(contentsOfFile: KoePaths.dictionaryFile, encoding: .utf8)) ?? ""
    }

    private func save() {
        try? text.write(toFile: KoePaths.dictionaryFile, atomically: true, encoding: .utf8)
    }
}

// MARK: - System Prompt Settings

private struct PromptSettingsTab: View {
    let appState: AppState
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
        text = (try? String(contentsOfFile: KoePaths.systemPromptFile, encoding: .utf8)) ?? ""
    }

    private func save() {
        try? text.write(toFile: KoePaths.systemPromptFile, atomically: true, encoding: .utf8)
        appState.reloadConfig()
    }
}
