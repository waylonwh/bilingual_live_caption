import AVFoundation
import CaptionCore
import Speech

@MainActor
final class AppleTranscriber {
    private var analyzer: SpeechAnalyzer?
    private var converter: AnalyzerInputConverter?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
    private var sampleCount: Int64 = 0
    private var stopped = false
    var onText: ((String, String, Bool) -> Void)?
    var onFailure: ((String) -> Void)?

    static func module(language: String) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw CaptionError("Apple speech recognition is unavailable on this Mac.") }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw CaptionError("Apple speech recognition does not support the selected source language on this Mac.")
        }
        return SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
    }

    static func isInstalled(language: String) async throws -> Bool {
        let transcriber = try await module(language: language)
        return await AssetInventory.status(forModules: [transcriber]) == .installed
    }

    static func install(language: String, progress: @escaping (Progress) -> Void) async throws {
        let transcriber = try await module(language: language)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            progress(request.progress)
            try await request.downloadAndInstall()
        }
    }

    func start(language: String, keywords: [String]) async throws {
        let transcriber = try await Self.module(language: language)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw CaptionError("The Apple language model is not ready. Use Prepare Apple Model before starting local transcription.")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw CaptionError("Apple speech recognition has no compatible audio format.")
        }
        self.analyzer = analyzer
        converter = AnalyzerInputConverter(analyzerFormat: format)
        if !keywords.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = keywords
            try await analyzer.setContext(context)
        }
        let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(100))
        self.continuation = continuation
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, !self.stopped else { return }
                    let id = "apple-\(result.range.start.value)-\(result.range.start.timescale)"
                    self.onText?(id, String(result.text.characters), result.isFinal)
                }
            } catch {
                guard let self, !self.stopped else { return }
                self.onFailure?("Apple transcription failed: \(error.localizedDescription)")
            }
        }
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: input)
    }

    func enqueue(_ frame: AudioFrame) throws {
        guard !stopped, let converter, let continuation else { return }
        let count = frame.pcm.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count)),
              let destination = buffer.int16ChannelData?.pointee else { throw CaptionError("Unable to allocate an Apple audio buffer.") }
        buffer.frameLength = AVAudioFrameCount(count)
        frame.pcm.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { memcpy(destination, base, bytes.count) }
        }
        let time = AVAudioTime(sampleTime: sampleCount, atRate: 24000)
        sampleCount += Int64(count)
        for input in try converter.convert(buffer, at: time) {
            if case .dropped = continuation.yield(input) {
                throw CaptionError("Apple transcription fell behind. Stop and restart captions.")
            }
        }
    }

    func stop(gracefully: Bool = false) async {
        if gracefully, let analyzer {
            let watchdog = Task {
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
                await analyzer.cancelAndFinishNow()
            }
            if let converter, let remaining = try? converter.flush() {
                for input in remaining { continuation?.yield(input) }
            }
            continuation?.finish()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            watchdog.cancel()
        }
        stopped = true
        continuation?.finish()
        continuation = nil
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        converter = nil
    }
}
