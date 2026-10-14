import CaptionCore
import Foundation
import OSLog

@MainActor
final class RealtimeStream {
    var onEvent: (([String: Any]) -> Void)?
    var onFailure: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    private let makeClient: () -> RealtimeClient
    private var current: RealtimeClient?
    private var pending: RealtimeClient?
    private var retiring: RealtimeClient?
    private var renewal: Task<Void, Never>?
    private var stopped = false
    private var key = ""
    private var language = ""
    private var keywords: [String] = []
    private var quietSamples = 0
    private var receivedAudio = false
    var audioTime = 0.0
    private let logger = Logger(subsystem: "net.waylonwu.bilingual-live-caption", category: "connection")

    init(kind: RealtimeProtocol.Kind, makeClient: (() -> RealtimeClient)? = nil) {
        self.makeClient = makeClient ?? { RealtimeClient(kind: kind) }
    }

    func start(key: String, language: String, keywords: [String] = []) async throws {
        self.key = key
        self.language = language
        self.keywords = keywords
        let client = makeClient()
        current = client
        connectCallbacks(client)
        try await client.start(key: key, language: language, keywords: keywords)
    }

    func enqueue(_ frame: AudioFrame) {
        if current?.recordingOffset == nil { current?.recordingOffset = audioTime }
        audioTime += frame.duration
        receivedAudio = true
        quietSamples = frame.rms <= 0.006 ? quietSamples + frame.pcm.count / 2 : 0
        current?.enqueue(frame)
    }

    func stop(gracefully: Bool = true) async -> Bool {
        stopped = true
        renewal?.cancel()
        if let pending, pending !== current { _ = await pending.stop(gracefully: false) }
        await renewal?.value
        let drained = await current?.stop(gracefully: gracefully) ?? true
        pending = nil
        retiring = nil
        current = nil
        key = ""
        return drained
    }

    private func connectCallbacks(_ client: RealtimeClient) {
        client.onEvent = { [weak self] event in self?.onEvent?(event) }
        client.onFailure = { [weak self, weak client] message in
            guard let self, !self.stopped, self.current === client else { return }
            self.onFailure?(message)
        }
        client.onReconnectNeeded = { [weak self, weak client] message in
            guard let self, !self.stopped, self.current === client, self.renewal == nil else { return }
            self.logger.notice("Session replacement: \(message, privacy: .public)")
            self.onStatus?("Reconnecting — \(message)")
            self.renewal = Task { await self.replaceSession() }
        }
    }

    private func replaceSession() async {
        defer { renewal = nil }
        for attempt in 1...3 {
            guard !stopped, !Task.isCancelled else { return }
            let next = makeClient()
            pending = next
            do {
                try await next.start(key: key, language: language, keywords: keywords)
                let boundaryDeadline = Date().addingTimeInterval(5)
                while current?.isAvailable == true, next.isAvailable, receivedAudio, quietSamples < 19_200, Date() < boundaryDeadline {
                    try await Task.sleep(for: .milliseconds(25))
                }
                try Task.checkCancellation()
                guard !stopped else { _ = await next.stop(gracefully: false); return }
                guard next.isAvailable else { throw CaptionError(next.failureMessage ?? "The replacement session closed before handoff.") }
                let old = current
                var bufferedEvents: [[String: Any]] = []
                next.onEvent = { bufferedEvents.append($0) }
                current = next
                retiring = old
                next.onFailure = { [weak self] message in
                    guard let self, !self.stopped else { return }
                    self.onFailure?(message)
                }
                let drained = await old?.stop() ?? true
                for event in bufferedEvents { onEvent?(event) }
                connectCallbacks(next)
                pending = nil
                retiring = nil
                guard !stopped, !Task.isCancelled else { return }
                onStatus?(drained ? "Listening" : "Listening — some final words from the previous session may be missing")
                return
            } catch {
                _ = await next.stop(gracefully: false)
                pending = nil
                guard !stopped, !Task.isCancelled else { return }
                let message = error.localizedDescription.replacingOccurrences(of: key, with: "[redacted]")
                logger.notice("Session replacement attempt \(attempt) failed: \(message, privacy: .public)")
                if !next.failureIsRetryable || attempt == 3 {
                    onFailure?("Could not reconnect. \(message)")
                    return
                }
                onStatus?("Reconnecting — attempt \(attempt + 1) of 3")
                do { try await Task.sleep(for: .seconds(attempt)) }
                catch { return }
            }
        }
    }
}
