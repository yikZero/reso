import Foundation
import SwiftData

@Model
final class SessionHistory {
    var startedAt: Date
    var durationMs: Int
    var text: String
    var characterCount: Int
    var wordCount: Int

    init(durationMs: Int, text: String) {
        self.startedAt = Date()
        self.durationMs = durationMs
        self.text = text
        (self.characterCount, self.wordCount) = Self.countText(text)
    }

    static func countText(_ text: String) -> (chars: Int, words: Int) {
        var charCount = 0
        var wordCount = 0
        var inWord = false

        for scalar in text.unicodeScalars {
            let v = scalar.value
            let isCJK = (v >= 0x4E00 && v <= 0x9FFF)
                || (v >= 0x3400 && v <= 0x4DBF)
                || (v >= 0xF900 && v <= 0xFAFF)

            if isCJK {
                charCount += 1
                if inWord { wordCount += 1; inWord = false }
            } else if scalar.properties.isAlphabetic || scalar == "'" || scalar.properties.numericType != nil {
                if !inWord { inWord = true }
                charCount += 1
            } else {
                if inWord { wordCount += 1; inWord = false }
            }
        }
        if inWord { wordCount += 1 }

        return (charCount, wordCount)
    }
}
