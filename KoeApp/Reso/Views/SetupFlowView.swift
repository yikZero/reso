import SwiftUI

struct SetupFlowView: View {
    @Environment(AppState.self) private var appState

    @State private var apiKey: String = ""
    @State private var triggerKey: String = "fn"
    @State private var cancelKey: String = "left_option"
    @State private var errorMessage: String?

    private let keyOptions = [
        ("fn", "Fn"),
        ("left_option", "Left Option"),
        ("right_option", "Right Option"),
        ("left_command", "Left Command"),
        ("right_command", "Right Command"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Setup Required")
                .font(.headline)

            Text("Enter your Gemini API key to get started.")
                .font(.caption)
                .foregroundStyle(.secondary)

            SecureField("API Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text("Trigger Key:")
                    .font(.caption)
                Picker("", selection: $triggerKey) {
                    ForEach(keyOptions, id: \.0) { key, label in
                        Text(label).tag(key)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }

            HStack {
                Text("Cancel Key:")
                    .font(.caption)
                Picker("", selection: $cancelKey) {
                    ForEach(keyOptions, id: \.0) { key, label in
                        Text(label).tag(key)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            Button("Save & Start") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .disabled(apiKey.isEmpty)
        }
        .padding(14)
        .frame(width: 260)
    }

    private func save() {
        guard triggerKey != cancelKey else {
            errorMessage = "Trigger and cancel keys must be different."
            return
        }

        let configDir = NSHomeDirectory() + "/.koe"
        let configPath = configDir + "/config.yaml"

        var yaml = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        if yaml.isEmpty {
            yaml = """
            asr:
              api_key: ""
              model: "gemini-3.1-flash-live-preview"
              connect_timeout_ms: 5000
              final_wait_timeout_ms: 10000
              system_prompt_path: "system_prompt.txt"

            feedback:
              start_sound: false
              stop_sound: false
              error_sound: false

            appearance:
              hide_menu_icon: false

            hotkey:
              trigger_key: "fn"
              cancel_key: "left_option"

            dictionary:
              path: "dictionary.txt"
            """
        }

        yaml = yamlSet(yaml, key: "api_key", value: apiKey)
        yaml = yamlSet(yaml, key: "trigger_key", value: triggerKey)
        yaml = yamlSet(yaml, key: "cancel_key", value: cancelKey)

        do {
            try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
            try yaml.write(toFile: configPath, atomically: true, encoding: .utf8)
            appState.reloadConfig()
            errorMessage = nil
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }
    }

    private func yamlSet(_ yaml: String, key: String, value: String) -> String {
        let pattern = "(\(key):\\s*).*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return yaml }
        let range = NSRange(yaml.startIndex..., in: yaml)
        let quoted = "\"\(value)\""
        return regex.stringByReplacingMatches(in: yaml, range: range, withTemplate: "$1\(quoted)")
    }
}
