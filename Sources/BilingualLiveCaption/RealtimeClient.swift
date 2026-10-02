import CaptionCore
import Foundation

@MainActor
final class RealtimeClient {
    let kind: RealtimeProtocol.Kind
    var onEvent: (([String: Any]) -> Void)?
    var onFailure: ((String) -> Void)?
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
    private var outstandingTurns = 0
    private var completedTurns = Set<String>()
    private var expiresAt: Date?
    private var expirationTask: Task<Void, Never>?
    private var sentAudio = false

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
                    if self.kind == .transcription && self.detector.append(frame) {
                        try await self.commit()
                    }
                }
            } catch {
                if !self.closing { self.fail(error.localizedDescription) }
            }
        }
        expirationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !self.closing else { return }
                if let expiresAt = self.expiresAt, expiresAt.timeIntervalSinceNow < 10 {
                    self.fail("The session is about to expire. Restart captions to open a new session.")
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
                guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = event["type"] as? String else { continue }
                switch type {
                case "session.created", "transcription_session.created":
                    created = true
                case "session.updated", "transcription_session.updated":
                    configured = true
                case "session.closed":
                    closed = true
                    if !closing { fail("The server closed the session. Restart captions to continue.") }
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
                if type != "session.output_audio.delta" { onEvent?(event) }
                if closed { return }
            }
        } catch {
            if !closing && !Task.isCancelled { fail(error.localizedDescription) }
        }
    }

    private var label: String { kind == .translation ? "translation" : "transcription" }

    private func fail(_ message: String) {
        guard failure == nil else { return }
        let redacted = key.isEmpty ? message : message.replacingOccurrences(of: key, with: "[redacted]")
        failure = "\(label.capitalized): \(String(redacted.prefix(600)))"
        if !closing { onFailure?(failure!) }
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
