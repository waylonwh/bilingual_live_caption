import Foundation
import NaturalLanguage

@MainActor
public final class SentenceFormatter {
    private let tokenizer = NLTokenizer(unit: .sentence)
    private var previousText = ""
    private var previousLanguage = ""
    private var previousResult = ""

    public init() {}

    public func format(_ text: String, language: String) -> String {
        if text == previousText, language == previousLanguage { return previousResult }
        let code = language.split(separator: "-").first.map(String.init) ?? language
        tokenizer.setLanguage(code == "zh" ? .simplifiedChinese : NLLanguage(rawValue: code))
        tokenizer.string = text
        let sentences = tokenizer.tokens(for: text.startIndex..<text.endIndex)
            .map { text[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let result = sentences.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : sentences.joined(separator: "\n")
        previousText = text
        previousLanguage = language
        previousResult = result
        return result
    }
}
