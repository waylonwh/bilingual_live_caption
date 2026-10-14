import Foundation
import NaturalLanguage

@MainActor
public final class SentenceFormatter {
    private let tokenizer = NLTokenizer(unit: .sentence)
    private var previousText = ""
    private var previousLanguage = ""
    private var previousResult = ""
    private var previousWrap = false

    public init() {}

    public func format(_ text: String, language: String, wrapLongClauses: Bool = false) -> String {
        if text == previousText, language == previousLanguage, wrapLongClauses == previousWrap { return previousResult }
        let code = language.split(separator: "-").first.map(String.init) ?? language
        tokenizer.setLanguage(code == "zh" ? .simplifiedChinese : NLLanguage(rawValue: code))
        let sentences = text.components(separatedBy: .newlines).flatMap { paragraph -> [String] in
            tokenizer.string = paragraph
            return tokenizer.tokens(for: paragraph.startIndex..<paragraph.endIndex)
                .map { paragraph[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }.flatMap { sentence -> [String] in
            guard wrapLongClauses else { return [sentence] }
            let limit = ["zh", "ja", "ko"].contains(code) ? 32 : 96
            let characters = Array(sentence)
            var lines: [String] = []
            var line = ""
            for (index, character) in characters.enumerated() {
                line.append(character)
                let numericComma = character == "," && index > 0 && index + 1 < characters.count &&
                    characters[index - 1].isNumber && characters[index + 1].isNumber
                if line.count >= limit, ",，;；".contains(character), !numericComma {
                    lines.append(line.trimmingCharacters(in: .whitespaces))
                    line = ""
                }
            }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line.trimmingCharacters(in: .whitespaces)) }
            return lines
        }
        let result = sentences.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : sentences.joined(separator: "\n")
        previousText = text
        previousLanguage = language
        previousResult = result
        previousWrap = wrapLongClauses
        return result
    }
}
