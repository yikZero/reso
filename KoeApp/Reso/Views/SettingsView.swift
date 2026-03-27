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
        .scenePadding()
        .frame(width: 480, height: 360)
    }
}

// MARK: - ASR Settings

private struct AsrSettingsTab: View {
    let appState: AppState
    @State private var apiKey = ""
    @State private var model = ""
    @State private var showKey = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
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

                    TextField("Model", text: $model)
                        .textFieldStyle(.plain)
                } header: {
                    Text("Gemini Live API")
                } footer: {
                    Text("Configure the Gemini API key and model for speech recognition.")
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
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
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
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

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            } header: {
                Text("Keys")
            } footer: {
                Text("Hold the trigger key for dictation, or tap to toggle. Press cancel to abort.")
            }

            Section("Appearance") {
                Toggle("Hide menu bar icon", isOn: $hideMenuIcon)
            }
        }
        .formStyle(.grouped)
        .onAppear { load() }
        .onChange(of: triggerKey) { save() }
        .onChange(of: cancelKey) { save() }
        .onChange(of: hideMenuIcon) { save() }
    }

    private func load() {
        let yaml = koeReadConfig()
        let t = koeYamlRead(yaml, key: "trigger_key")
        triggerKey = t.isEmpty ? "fn" : t
        let c = koeYamlRead(yaml, key: "cancel_key")
        cancelKey = c.isEmpty ? "left_option" : c
        hideMenuIcon = koeYamlRead(yaml, key: "hide_menu_icon") == "true"
        loaded = true
    }

    private func save() {
        guard loaded else { return }
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
        VStack(alignment: .leading, spacing: 0) {
            Text("One term per line. These help improve recognition accuracy.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.background)
                        .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                )
                .padding(.horizontal, 12)

            HStack {
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
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
        VStack(alignment: .leading, spacing: 0) {
            Text("System prompt sent to Gemini for recognition and correction.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.background)
                        .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                )
                .padding(.horizontal, 12)

            HStack {
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
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
