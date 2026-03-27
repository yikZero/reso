import Foundation

// MARK: - Paths

enum KoePaths {
    static let configDir = NSHomeDirectory() + "/.koe"
    static let configFile = configDir + "/config.yaml"
    static let dictionaryFile = configDir + "/dictionary.txt"
    static let systemPromptFile = configDir + "/system_prompt.txt"
}

// MARK: - Key Options

let koeKeyOptions: [(key: String, label: String)] = [
    ("fn", "Fn"),
    ("left_option", "Left Option"),
    ("right_option", "Right Option"),
    ("left_command", "Left Command"),
    ("right_command", "Right Command"),
]

// MARK: - YAML Helpers

func koeReadConfig() -> String {
    (try? String(contentsOfFile: KoePaths.configFile, encoding: .utf8)) ?? ""
}

func koeWriteConfig(_ yaml: String) {
    try? yaml.write(toFile: KoePaths.configFile, atomically: true, encoding: .utf8)
}

func koeYamlRead(_ yaml: String, key: String) -> String {
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

func koeYamlWrite(_ yaml: String, key: String, value: String) -> String {
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
