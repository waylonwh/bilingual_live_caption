@testable import BilingualLiveCaption
import CaptionCore
import Foundation
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
