@testable import BilingualLiveCaption
import Foundation
import Testing

@Test func recordingRevisionsReplaceInsteadOfDuplicating() throws {
    var recording = CaptionRecording()
    recording.source(id: "b", text: "Later.", start: 10, end: 12)
    recording.source(id: "a", text: "Wrong", start: 0, end: 2)
    recording.source(id: "a", text: "Correct.\n", start: 0, end: 2, final: true)
    recording.source(id: "a", text: "duplicate", start: 0, end: 2, append: true)
    recording.translated("正确。\n", time: 2)
    recording.translated("后来。", time: 12, boundary: true)
    let pairs = recording.pairs(sourceLanguage: "en", targetLanguage: "zh")
    #expect(pairs.map(\.original).joined() == "Correct.\nLater.")
    #expect(pairs.map(\.translation).joined() == "正确。\n后来。")
    #expect(pairs.first?.original.contains("Correct.") == true)
    #expect(!pairs.contains { $0.original.contains("Wrong") || $0.original.contains("duplicate") })
}

@Test func recordingMatchesManyToOneAndRetainsUnmatchedText() {
    var recording = CaptionRecording()
    recording.source(id: "a", text: "First. Second. Third.", start: 0, end: 6)
    recording.translated("第一、第二和第三。", time: 6)
    recording.source(id: "b", text: "Untranslated.", start: 30, end: 32)
    let pairs = recording.pairs(sourceLanguage: "en", targetLanguage: "zh")
    #expect(pairs.count == 2)
    #expect(pairs[0].original == "First. Second. Third.")
    #expect(pairs[0].translation == "第一、第二和第三。")
    #expect(pairs[1].original == "Untranslated.")
    #expect(pairs[1].translation == "")
}

@Test func recordingHasThreeMachineReadableLinesAndPreservesEscapedText() throws {
    var recording = CaptionRecording()
    let source = "A \"quote\", a \\ slash\nnext line."
    let target = "引号\"与换行\n下一行。"
    recording.source(id: "a", text: source, start: 3661.002, end: 3663)
    recording.translated(target, time: 3663)
    let text = try recording.text(sourceLanguage: "en", targetLanguage: "zh")
    let blocks = text.components(separatedBy: "\n\n").filter { !$0.isEmpty }
    var restoredSource = ""
    var restoredTarget = ""
    for block in blocks {
        let lines = block.components(separatedBy: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].contains(" --> "))
        restoredSource += try JSONDecoder().decode(String.self, from: Data(lines[1].utf8))
        restoredTarget += try JSONDecoder().decode(String.self, from: Data(lines[2].utf8))
    }
    #expect(text.hasPrefix("01:01:01.002 --> "))
    #expect(restoredSource == source)
    #expect(restoredTarget == target)
}

@Test func recordingFileUpdatesAtomicallyWithoutOverwritingAnotherSession() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let date = Date(timeIntervalSince1970: 0)
    let first = try CaptionRecordingFile(directory: directory, date: date)
    let second = try CaptionRecordingFile(directory: directory, date: date)
    #expect(first.url != second.url)
    var recording = CaptionRecording()
    recording.source(id: "a", text: "Partial", start: 0, end: 1)
    try await first.write(recording, sourceLanguage: "en", targetLanguage: "zh")
    recording.source(id: "a", text: "Final.", start: 0, end: 2, final: true)
    recording.translated("结束。", time: 2)
    try await first.write(recording, sourceLanguage: "en", targetLanguage: "zh")
    let saved = try String(contentsOf: first.url, encoding: .utf8)
    #expect(saved.contains("Final.") && saved.contains("结束。") && !saved.contains("Partial"))
    #expect(try Data(contentsOf: second.url).isEmpty)
}

@Test func recordingKeepsLongUnpunctuatedTranslationsWithoutAddingPunctuation() {
    var recording = CaptionRecording()
    let chunks = ["很长的第一段，", "继续说下去，", "最后的内容"]
    for (index, text) in chunks.enumerated() {
        recording.translated(text, time: Double(index * 15))
    }
    let pairs = recording.pairs(sourceLanguage: "en", targetLanguage: "zh")
    #expect(pairs.count == 3)
    #expect(pairs.map(\.translation).joined() == chunks.joined())
    #expect(pairs.allSatisfy { $0.original.isEmpty })
}
