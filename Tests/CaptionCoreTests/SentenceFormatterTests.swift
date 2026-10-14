@testable import BilingualLiveCaption
import CaptionCore
import Foundation
import CoreMedia
import Speech
import Testing

@MainActor
@Test func sentenceFormattingKeepsAbbreviationsNumbersAndQuotes() {
    let formatter = SentenceFormatter()
    #expect(formatter.format("Dr. Smith measured 3.14 metres. The U.S. coast is cold. Next sentence", language: "en-US") ==
            "Dr. Smith measured 3.14 metres.\nThe U.S. coast is cold.\nNext sentence")
    #expect(formatter.format("Use e.g. ice. Visit example.com. Wait... really? Yes!", language: "en-AU") ==
            "Use e.g. ice.\nVisit example.com.\nWait... really?\nYes!")
    #expect(formatter.format("She said, \"Hello.\" Then left.", language: "en-US") ==
            "She said, \"Hello.\"\nThen left.")
    #expect(formatter.format("他说：“好了。”然后离开。下一句还没", language: "zh-CN") ==
            "他说：“好了。”\n然后离开。\n下一句还没")
    #expect(formatter.format("最初の文です。次の文です！まだ", language: "ja-JP") ==
            "最初の文です。\n次の文です！\nまだ")
}

@MainActor
@Test func unfinishedSentencesAppearImmediatelyWithoutEmptyLines() {
    let formatter = SentenceFormatter()
    for text in ["H", "Hello", "Hello.", "Hello. ", "Hello. N", "Hello. Next"] {
        let expected = text.hasPrefix("Hello. N") ? text.replacingOccurrences(of: ". ", with: ".\n") : text.trimmingCharacters(in: .whitespaces)
        #expect(formatter.format(text, language: "en") == expected)
    }
    for text in ["Dr.", "Dr. ", "Dr. S", "Dr. Smith"] {
        #expect(formatter.format(text, language: "en") == text.trimmingCharacters(in: .whitespaces))
    }
    #expect(formatter.format("第一句。", language: "zh") == "第一句。")
    #expect(formatter.format("第一句。第", language: "zh") == "第一句。\n第")
    #expect(formatter.format("still speaking without punctuation", language: "en") == "still speaking without punctuation")
}

@MainActor
@Test func revisedTranscriptsReplaceOldSentenceBoundaries() {
    let formatter = SentenceFormatter()
    #expect(formatter.format("Sea ice. Is changing", language: "en") == "Sea ice.\nIs changing")
    #expect(formatter.format("Sea ice is changing. New data", language: "en") == "Sea ice is changing.\nNew data")
    #expect(formatter.format("New data", language: "en") == "New data")
    #expect(formatter.format("", language: "en") == "")
    #expect(formatter.format(" \n ", language: "en") == "")
    #expect(formatter.format("新的句子。继续", language: "zh") == "新的句子。\n继续")
}

@MainActor
@Test func streamingFormattingNeverDropsVisibleCharacters() {
    let formatter = SentenceFormatter()
    let samples = [
        ("Dr. Smith said, \"Use 3.14, e.g. here.\" Really? Wait... yes! 🌊 Next", "en"),
        ("他说：“第一句！”接着说（第二句）。真的？海冰🧊正在变化", "zh")
    ]
    for (text, language) in samples {
        var partial = ""
        for character in text {
            partial.append(character)
            let formatted = formatter.format(partial, language: language)
            #expect(formatted.filter { !$0.isWhitespace } == partial.filter { !$0.isWhitespace })
            #expect(!formatted.hasSuffix("\n"))
            #expect(!formatted.contains("\n\n"))
        }
    }
}

@MainActor
@Test func captionModelFormatsBothLanesWithoutChangingRawText() {
    let model = CaptionModel(environment: [:])
    model.original = "First sentence. Next"
    model.translation = "第一句。接下来"
    #expect(model.originalCaption == "First sentence.\nNext")
    #expect(model.translationCaption == "第一句。\n接下来")
    #expect(model.original == "First sentence. Next")
    #expect(model.translation == "第一句。接下来")
    model.original = "First sentence continues"
    #expect(model.originalCaption == "First sentence continues")
    #expect(model.translationCaption == "第一句。\n接下来")
    model.clearCaptions()
    #expect(model.originalCaption.isEmpty && model.translationCaption.isEmpty)
}

@MainActor
@Test func appleAudioTimesSplitLongPausesAndHandleRevisions() {
    var first = AttributedString("That's the question ")
    first.audioTimeRange = CMTimeRange(start: CMTime(seconds: 0, preferredTimescale: 24000), duration: CMTime(seconds: 2, preferredTimescale: 24000))
    var second = AttributedString("Okay, I've got one final question.")
    second.audioTimeRange = CMTimeRange(start: CMTime(seconds: 3.2, preferredTimescale: 24000), duration: CMTime(seconds: 2, preferredTimescale: 24000))
    let formatter = SentenceFormatter()
    let display = AppleTranscriber.displayText(first + second, previousEnd: nil)
    #expect(AppleTranscriber.displayText(first + AttributedString(" ") + second, previousEnd: nil).contains("\n"))
    #expect(formatter.format(display, language: "en") == "That's the question\nOkay, I've got one final question.")
    #expect(String((first + second).characters) == "That's the question Okay, I've got one final question.")
    second.audioTimeRange = CMTimeRange(start: CMTime(seconds: 2.4, preferredTimescale: 24000), duration: CMTime(seconds: 2, preferredTimescale: 24000))
    #expect(!AppleTranscriber.displayText(first + second, previousEnd: nil).contains("\n"))
    #expect(AppleTranscriber.displayText(second, previousEnd: 1).hasPrefix("\n"))
}

@MainActor
@Test func longTranslationsBreakAtExistingCommasWithoutChangingCharacters() {
    let formatter = SentenceFormatter()
    let clause = String(repeating: "这是长译文", count: 7)
    let text = clause + ",谢谢大家加入我们,也感谢你们提出问题。"
    #expect(formatter.format(text, language: "zh", wrapLongClauses: true) == clause + ",\n谢谢大家加入我们,也感谢你们提出问题。")
    #expect(!formatter.format(text, language: "zh").contains("\n"))
    var partial = ""
    for character in text {
        partial.append(character)
        let display = formatter.format(partial, language: "zh", wrapLongClauses: true)
        #expect(display.filter { !$0.isWhitespace } == partial.filter { !$0.isWhitespace })
        #expect(!display.hasSuffix("\n") && !display.contains("\n\n"))
    }
    let number = clause + "1,234,567"
    #expect(formatter.format(number, language: "zh", wrapLongClauses: true) == number)
    #expect(formatter.format("第一段\n第二段\n\n第三段", language: "zh") == "第一段\n第二段\n第三段")
}

@Test func pauseDetectorUsesAudioDurationAndIgnoresInitialSilence() {
    var detector = CaptionPauseDetector()
    let silence = AudioFrame(pcm: Data(repeating: 0, count: 9600), sequence: 0)
    let speech = AudioFrame(pcm: Data(repeating: 0x10, count: 9600), sequence: 0)
    let frames = Array(repeating: false, count: 8) + [true] + Array(repeating: false, count: 5) +
        [true] + Array(repeating: false, count: 6) + [true, true]
    let boundaries = frames.map { detector.append($0 ? speech : silence) }
    #expect(boundaries.enumerated().filter { $0.element }.map { $0.offset } == [21])
}

@Test func displayBreaksSurviveFinalRevisionsWithoutChangingRawTranscripts() {
    var store = TranscriptStore()
    store.replace(id: "a", text: "First", final: true)
    store.breakBefore("b")
    store.delta(id: "b", text: "Okay")
    store.replace(id: "b", text: "Okay, next", final: true)
    #expect(store.text == "First Okay, next")
    #expect(store.displayText == "First\nOkay, next")
    store.replace(id: "c", text: "One Two", final: true, displayText: "One\nTwo")
    #expect(store.text == "First Okay, next One Two")
    #expect(store.displayText == "First\nOkay, next One\nTwo")
}
