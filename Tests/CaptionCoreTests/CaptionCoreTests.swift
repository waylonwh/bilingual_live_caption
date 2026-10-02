import CaptionCore
import Foundation
import Testing

@Test func audioFramingPreservesOrderAcrossCaptureCallbacks() {
    var framer = AudioFramer()
    let first = Data(repeating: 0x12, count: 3000)
    let second = Data(repeating: 0x34, count: 9000)
    let firstAccepted = framer.append(first)
    let secondAccepted = framer.append(second)
    #expect(firstAccepted && secondAccepted)
    let a = framer.next()
    let b = framer.next()
    #expect(a.pcm == first + Data(repeating: 0x34, count: 6600))
    #expect(b.pcm == Data(repeating: 0x34, count: 2400) + Data(repeating: 0, count: 7200))
    #expect(a.sequence == 0 && b.sequence == 1)
    #expect(a.duration == 0.2)
    #expect(framer.next().pcm == Data(repeating: 0, count: AudioFrame.byteCount))
}

@Test func backlogAndPCMLevelsAreDetected() {
    var framer = AudioFramer()
    let accepted = framer.append(Data(repeating: 0, count: AudioFrame.byteCount * 11))
    #expect(!accepted)
    let silence = AudioFrame(pcm: Data(repeating: 0, count: 9600), sequence: 0)
    #expect(silence.rms == 0)
    let fullNegative = AudioFrame(pcm: Data([0x00, 0x80]), sequence: 0)
    #expect(fullNegative.rms == 1)
}

@Test func shortPausesDoNotSplitSpeechButLongPausesDo() {
    var detector = TurnBoundaryDetector()
    let speech = AudioFrame(pcm: Data(repeating: 0x20, count: 9600), sequence: 0)
    let silence = AudioFrame(pcm: Data(repeating: 0, count: 9600), sequence: 0)
    let first = detector.append(speech)
    let shortPause = (0..<3).map { _ in detector.append(silence) }
    let end = detector.append(silence)
    #expect(!first && shortPause.allSatisfy { !$0 })
    #expect(end)
    #expect(!detector.hasPendingAudio)
    let continuous = (0..<74).map { _ in detector.append(speech) }
    let maximumLength = detector.append(speech)
    #expect(continuous.allSatisfy { !$0 })
    #expect(maximumLength)
}

@Test func finalTranscriptsReplacePartialTextAndKeepTurnOrder() {
    var store = TranscriptStore()
    store.register("first")
    store.register("second", after: "first")
    store.delta(id: "first", text: "sea eyes")
    store.replace(id: "second", text: "are changing.", final: true)
    store.replace(id: "first", text: "Sea ice conditions", final: true)
    store.delta(id: "first", text: " stale")
    #expect(store.text == "Sea ice conditions are changing.")
}

@Test func appleVolatileUpdatesDoNotDuplicateWords() {
    var store = TranscriptStore(limit: 2)
    store.replace(id: "range1", text: "A wave", final: false)
    store.replace(id: "range1", text: "A wave model", final: false)
    store.replace(id: "range1", text: "A wave model.", final: true)
    store.replace(id: "range2", text: "Next sentence.", final: true)
    #expect(store.text == "A wave model. Next sentence.")
    store.replace(id: "range3", text: "Third.", final: true)
    #expect(store.text == "Next sentence. Third.")
}

@Test func translationDisablesDuplicateTranscriptionAndUsesDedicatedEvents() throws {
    let config = RealtimeProtocol.configuration(for: .translation, language: "zh")
    let data = try JSONSerialization.data(withJSONObject: config)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"transcription\":null"))
    #expect(text.contains("\"language\":\"zh\""))
    #expect(!text.contains("turn_detection"))
    let frame = AudioFrame(pcm: Data([0, 0, 1, 0]), sequence: 1)
    let event = RealtimeProtocol.append(frame, kind: .translation)
    #expect(event["type"] as? String == "session.input_audio_buffer.append")
    #expect(Data(base64Encoded: event["audio"] as! String) == frame.pcm)
}

@Test func cloudTranscriptionUsesLiveModelWithoutServerVAD() throws {
    let data = try JSONSerialization.data(withJSONObject: RealtimeProtocol.configuration(for: .transcription, language: "en", keywords: ["CICE"]))
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("gpt-live-transcribe"))
    #expect(text.contains("\"turn_detection\":null"))
    #expect(text.contains("CICE"))
    #expect(RealtimeProtocol.url(for: .transcription).query == "intent=transcription")
}
