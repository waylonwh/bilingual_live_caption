import Foundation
import NaturalLanguage

struct RecordedText {
    var text: String
    var start: Double
    var end: Double
}

struct RecordedPair {
    var original: String
    var translation: String
    var start: Double
    var end: Double
}

struct CaptionRecording {
    private var originals: [String: RecordedText] = [:]
    private var order: [String] = []
    private var finalized = Set<String>()
    private var translations: [RecordedText] = []
    private var translationBreaks = Set<Int>()

    mutating func source(id: String, text: String, start: Double, end: Double, append: Bool = false, final: Bool = false) {
        guard start.isFinite, end.isFinite, !finalized.contains(id) else { return }
        if originals[id] == nil { order.append(id) }
        let value = append ? (originals[id]?.text ?? "") + text : text
        originals[id] = RecordedText(text: value, start: max(0, start), end: max(start, end))
        if final { finalized.insert(id) }
    }

    mutating func translated(_ text: String, time: Double, boundary: Bool = false) {
        guard !text.isEmpty, time.isFinite else { return }
        if boundary { translationBreaks.insert(translations.count) }
        translations.append(RecordedText(text: text, start: max(0, time), end: max(0, time)))
    }

    func pairs(sourceLanguage: String, targetLanguage: String) -> [RecordedPair] {
        let source = order.compactMap { originals[$0] }.sorted { $0.start < $1.start }
            .flatMap { Self.sentences([$0], language: sourceLanguage) }
        var target: [RecordedText] = []
        var pending: [RecordedText] = []
        for (index, text) in translations.enumerated() {
            let age = text.start - (pending.first?.start ?? text.start)
            let last = pending.last?.text.last
            let atWordBoundary = text.text.first?.isWhitespace == true || last?.isWhitespace == true
            let atClauseBoundary = last.map { ",，;；。.!?！？".contains($0) } == true
            if translationBreaks.contains(index) || (age >= 12 && atClauseBoundary) || (age >= 20 && atWordBoundary) {
                target += Self.sentences(pending, language: targetLanguage)
                pending = []
            }
            pending.append(text)
        }
        target += Self.sentences(pending, language: targetLanguage)
        var result: [RecordedPair] = []
        var i = 0
        var j = 0
        while i < source.count || j < target.count {
            let sourceLimit = Self.groupLimit(source, from: i)
            let targetLimit = Self.groupLimit(target, from: j)
            var a = 0
            var b = 0
            if i == source.count { b = 1 }
            else if j == target.count { a = 1 }
            else if source[i + sourceLimit - 1].end + 3 < target[j].start { a = 1 }
            else if target[j + targetLimit - 1].end + 3 < source[i].start { b = 1 }
            else {
                var best = Double.infinity
                for x in 1...sourceLimit {
                    for y in 1...targetLimit {
                        let distance = abs(source[i + x - 1].end - target[j + y - 1].end)
                        let cost = distance + Double(x + y - 2) * 0.35
                        if cost < best { best = cost; a = x; b = y }
                    }
                }
            }
            let left = Array(source[i..<(i + a)])
            let right = Array(target[j..<(j + b)])
            let both = left + right
            result.append(RecordedPair(original: left.map(\.text).joined(), translation: right.map(\.text).joined(),
                start: both.map(\.start).min() ?? 0, end: both.map(\.end).max() ?? 0))
            i += a
            j += b
        }
        return result
    }

    private static func groupLimit(_ texts: [RecordedText], from index: Int) -> Int {
        guard index < texts.count else { return 0 }
        var count = 1
        while count < 3, index + count < texts.count,
              texts[index + count].start - texts[index + count - 1].end <= 3 { count += 1 }
        return count
    }

    func text(sourceLanguage: String, targetLanguage: String) throws -> String {
        try pairs(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage).map { pair in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let source = String(decoding: try encoder.encode(pair.original), as: UTF8.self)
            let target = String(decoding: try encoder.encode(pair.translation), as: UTF8.self)
            return "\(Self.timestamp(pair.start)) --> \(Self.timestamp(pair.end))\n\(source)\n\(target)\n\n"
        }.joined()
    }

    private static func timestamp(_ seconds: Double) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    private static func sentences(_ parts: [RecordedText], language: String) -> [RecordedText] {
        let text = parts.map(\.text).joined()
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.setLanguage(NLLanguage(rawValue: String(language.prefix(2))))
        tokenizer.string = text
        let ranges = tokenizer.tokens(for: text.startIndex..<text.endIndex)
        var ends = ranges.map(\.upperBound)
        if ends.last != text.endIndex { ends.append(text.endIndex) }
        var start = text.startIndex
        var lower = 0
        var partIndex = 0
        var offset = 0
        let counts = parts.map { $0.text.count }
        var result: [RecordedText] = []
        for end in ends where end > start {
            let upper = lower + text.distance(from: start, to: end)
            var times: [Double] = []
            while partIndex < parts.count, offset < upper {
                let part = parts[partIndex]
                let count = counts[partIndex]
                if count > 0, offset < upper, offset + count > lower {
                    let lo = Double(max(lower - offset, 0)) / Double(count)
                    let hi = Double(min(upper - offset, count)) / Double(count)
                    times += [part.start + (part.end - part.start) * lo, part.start + (part.end - part.start) * hi]
                }
                if offset + count > upper { break }
                offset += count
                partIndex += 1
            }
            result.append(RecordedText(text: String(text[start..<end]), start: times.min() ?? 0, end: times.max() ?? 0))
            start = end
            lower = upper
        }
        return result
    }
}

actor CaptionRecordingFile {
    nonisolated let url: URL

    init(directory: URL, date: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = date.ISO8601Format().replacingOccurrences(of: ":", with: "-")
        url = directory.appendingPathComponent("\(stamp)-\(UUID().uuidString).txt")
        try Data().write(to: url, options: .withoutOverwriting)
    }

    func write(_ recording: CaptionRecording, sourceLanguage: String, targetLanguage: String) throws {
        let text = try recording.text(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}
