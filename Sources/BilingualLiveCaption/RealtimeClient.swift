import CaptionCore
import Foundation

@MainActor
final class RealtimeClient {
    let kind: RealtimeProtocol.Kind
    var onEvent: (([String: Any]) -> Void)?
    var onFailure: ((String) -> Void)?
    var onReconnectNeeded: ((String) -> Void)?
    var recordingOffset: Double?
    private var audioTime = 0.0
    private var turnStart = 0.0
    private var committedRanges: [(Double, Double)] = []
    private var itemRanges: [String: (Double, Double)] = [:]
    private(set) var failureIsRetryable = true
    private var connection: RealtimeConnection?
    private let makeConnection: @MainActor (URLRequest) -> RealtimeConnection
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var frames: AsyncStream<AudioFrame>.Continuation?
    private var created = false
    private var configured = false
    private var closed = false
    private var closing = false
    private var writerFinished = false
    private var failure: String?
    private var key = ""
    private var detector = TurnBoundaryDetector()
    private var pauseDetector = CaptionPauseDetector()
    private var pendingBreak = false
    private var committedBreaks: [Bool] = []
    private var translationPauses = CaptionPauseDetector()
    private var translationPauseTimes: [Double] = []
    private var lastTranslationCharacter: Character?
    private var outstandingTurns = 0
    private var completedTurns = Set<String>()
    private var expiresAt: Date?
    private var expirationTask: Task<Void, Never>?
    private var sentAudio = false
    var isAvailable: Bool { configured && failure == nil && !closed && !closing }
    var failureMessage: String? { failure }

    init(kind: RealtimeProtocol.Kind, makeConnection: @escaping @MainActor (URLRequest) -> RealtimeConnection = { OpenAIConnection(request: $0) }) {
        self.kind = kind
        self.makeConnection = makeConnection
    }

    func start(key: String, language: String, keywords: [String] = []) async throws {
        self.key = key
        var request = URLRequest(url: RealtimeProtocol.url(for: kind))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        connection = makeConnection(request)
        reader = Task { [weak self] in await self?.readEvents() }
        try await waitUntil(timeout: 15) { self.created }
        try await send(RealtimeProtocol.configuration(for: kind, language: language, keywords: keywords))
        try await waitUntil(timeout: 15) { self.configured }

        let (stream, continuation) = AsyncStream<AudioFrame>.makeStream(bufferingPolicy: .bufferingOldest(10))
        frames = continuation
        writer = Task { [weak self] in
            guard let self else { return }
            defer { self.writerFinished = true }
            do {
                for await frame in stream {
                    try Task.checkCancellation()
                    try await self.send(RealtimeProtocol.append(frame, kind: self.kind))
                    self.sentAudio = true
                    self.audioTime += frame.duration
                    if self.kind == .transcription {
                        if self.pauseDetector.append(frame) { self.pendingBreak = true }
                        if self.detector.append(frame) { try await self.commit() }
                    }
                }
            } catch {
                if !self.closing { self.fail(error.localizedDescription, reconnect: true) }
            }
        }
        expirationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !self.closing else { return }
                if let expiresAt = self.expiresAt, expiresAt.timeIntervalSinceNow < 60 {
                    self.onReconnectNeeded?("The session expires at \(expiresAt.ISO8601Format()).")
                    return
                }
            }
        }
    }

    func enqueue(_ frame: AudioFrame) {
        guard !closing, failure == nil, let frames else { return }
        if case .dropped = frames.yield(frame) {
            fail("The connection fell more than two seconds behind. Restart captions when the network is stable.")
        }
    }

    func stop(gracefully: Bool = true) async -> Bool {
        guard !closed else { disconnect(); return true }
        closing = true
        expirationTask?.cancel()
        frames?.finish()
        frames = nil
        let watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) }
            catch { return }
            self?.disconnect()
        }
        defer { watchdog.cancel() }
        var drained = !sentAudio
        if gracefully && !Task.isCancelled && configured && failure == nil {
            do {
                try await waitUntil(timeout: 2, checkCancellation: false) { self.writerFinished }
                if kind == .translation {
                    try await send(["type": "session.close"])
                    try await waitUntil(timeout: 5, checkCancellation: false) { self.closed }
                } else if sentAudio {
                    if detector.hasPendingAudio {
                        try await commit()
                        detector.reset()
                    }
                    try await waitUntil(timeout: 5, checkCancellation: false) { self.outstandingTurns == 0 }
                }
                drained = true
            } catch {
                drained = false
            }
        }
        disconnect()
        return drained
    }

    private func waitUntil(timeout: Double, checkCancellation: Bool = true, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if checkCancellation { try Task.checkCancellation() }
            if let failure { throw CaptionError(failure) }
            if Date() >= deadline { throw CaptionError("The \(label) connection timed out. Check your network, API key, and model access.") }
            if checkCancellation { try await Task.sleep(for: .milliseconds(25)) }
            else { try? await Task.sleep(for: .milliseconds(25)) }
        }
    }

    private func send(_ event: [String: Any]) async throws {
        guard let connection else { throw CaptionError("The \(label) connection is closed.") }
        let data = try JSONSerialization.data(withJSONObject: event)
        try await connection.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func commit() async throws {
        outstandingTurns += 1
        committedBreaks.append(pendingBreak)
        committedRanges.append((turnStart, audioTime))
        turnStart = audioTime
        pendingBreak = false
        try await send(["type": "input_audio_buffer.commit"])
    }

    private func readEvents() async {
        guard let connection else { return }
        do {
            while !Task.isCancelled {
                let message = try await connection.receive()
                let data: Data
                switch message {
                case .data(let bytes): data = bytes
                case .string(let text): data = Data(text.utf8)
                @unknown default: continue
                }
                guard var event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = event["type"] as? String else { continue }
                switch type {
                case "session.output_audio.delta":
                    if let time = event["elapsed_ms"] as? Double, time.isFinite,
                       (event["sample_rate"] as? Int ?? 24000) == 24000,
                       (event["channels"] as? Int ?? 1) == 1,
                       let encoded = event["delta"] as? String, let pcm = Data(base64Encoded: encoded) {
                        for offset in stride(from: 0, to: pcm.count, by: AudioFrame.byteCount) {
                            let frame = AudioFrame(pcm: pcm.subdata(in: offset..<min(offset + AudioFrame.byteCount, pcm.count)), sequence: 0)
                            if translationPauses.append(frame) {
                                translationPauseTimes.append(time + Double(offset) / 48)
                                translationPauseTimes = Array(translationPauseTimes.suffix(32))
                            }
                        }
                    } else { translationPauses = CaptionPauseDetector() }
                case "input_audio_buffer.committed":
                    if !committedBreaks.isEmpty { event["caption_break"] = committedBreaks.removeFirst() }
                    if !committedRanges.isEmpty, let id = event["item_id"] as? String {
                        itemRanges[id] = committedRanges.removeFirst()
                    }
                case "session.output_transcript.delta":
                    if let delta = event["delta"] as? String, !delta.isEmpty {
                        let time = event["elapsed_ms"] as? Double
                        let gap = time.map { time in translationPauseTimes.contains { $0 <= time } } ?? false
                        let continuesWord = lastTranslationCharacter.map { $0.isASCII && $0.isLetter } == true &&
                            delta.first.map { $0.isASCII && $0.isLetter } == true
                        let beginsWithPunctuation = delta.trimmingCharacters(in: .whitespacesAndNewlines).first.map { $0.isPunctuation } ?? true
                        event["caption_break"] = gap && !continuesWord && !beginsWithPunctuation
                        if gap, !continuesWord, !beginsWithPunctuation, let time {
                            translationPauseTimes.removeAll { $0 <= time }
                        }
                        lastTranslationCharacter = delta.last
                    }
                case "session.created", "transcription_session.created":
                    created = true
                case "session.updated", "transcription_session.updated":
                    configured = true
                case "session.closed":
                    closed = true
                    if !closing { fail("The server closed the session.", reconnect: true) }
                case "error":
                    let detail = event["error"] as? [String: Any]
                    fail(detail?["message"] as? String ?? "An API error occurred.")
                case "conversation.item.input_audio_transcription.completed":
                    if let id = event["item_id"] as? String, completedTurns.insert(id).inserted {
                        outstandingTurns = max(0, outstandingTurns - 1)
                    }
                case "conversation.item.input_audio_transcription.failed":
                    let detail = event["error"] as? [String: Any]
                    fail(detail?["message"] as? String ?? "A transcription segment failed.")
                default: break
                }
                if let session = event["session"] as? [String: Any], let expires = session["expires_at"] as? Double {
                    expiresAt = Date(timeIntervalSince1970: expires)
                }
                if let offset = recordingOffset {
                    if let id = event["item_id"] as? String, let range = itemRanges[id] {
                        event["recording_start"] = offset + range.0
                        event["recording_end"] = offset + range.1
                        if type == "conversation.item.input_audio_transcription.completed" { itemRanges.removeValue(forKey: id) }
                    }
                    if type == "session.output_transcript.delta" {
                        let time = (event["elapsed_ms"] as? Double).map { $0 / 1000 } ?? audioTime
                        event["recording_time"] = offset + time
                    }
                }
                if type != "session.output_audio.delta" { onEvent?(event) }
                if closed { return }
            }
        } catch {
            if !closing && !Task.isCancelled { fail(error.localizedDescription, reconnect: true) }
        }
    }

    private var label: String { kind == .translation ? "translation" : "transcription" }

    private func fail(_ message: String, reconnect: Bool = false) {
        guard failure == nil else { return }
        let redacted = key.isEmpty ? message : message.replacingOccurrences(of: key, with: "[redacted]")
        failure = "\(label.capitalized): \(String(redacted.prefix(600)))"
        failureIsRetryable = reconnect
        if !closing {
            if reconnect, configured, let onReconnectNeeded { onReconnectNeeded(failure!) }
            else { onFailure?(failure!) }
        }
    }

    private func disconnect() {
        closing = true
        frames?.finish()
        frames = nil
        writer?.cancel()
        reader?.cancel()
        expirationTask?.cancel()
        connection?.close()
        connection = nil
        key = ""
    }
}
