@testable import BilingualLiveCaption
import CaptionCore
import Foundation
import Testing

@MainActor
private final class MockConnection: RealtimeConnection {
    var sent: [[String: Any]] = []
    var events: [URLSessionWebSocketTask.Message] = []
    var receiver: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    var didClose = false
    var rejectConfiguration = false
    var emit: (([String: Any], MockConnection) -> Void)?

    init() { push(["type": "session.created"]) }

    func push(_ event: [String: Any]) {
        let bytes = try! JSONSerialization.data(withJSONObject: event)
        let message = URLSessionWebSocketTask.Message.data(bytes)
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: message)
        } else { events.append(message) }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard !didClose else { throw CaptionError("Closed") }
        guard case .string(let text) = message,
              let event = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        sent.append(event)
        if event["type"] as? String == "session.update" {
            if rejectConfiguration { push(["type": "error", "error": ["message": "Invalid test-secret key"]]) }
            else { push(["type": "session.updated"]) }
        }
        emit?(event, self)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        if !events.isEmpty { return events.removeFirst() }
        if didClose { throw CaptionError("Closed") }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }

    func close() {
        didClose = true
        receiver?.resume(throwing: CancellationError())
        receiver = nil
    }
}

@MainActor
@Test func translationDrainsFinalTextBeforeClosing() async throws {
    let connection = MockConnection()
    var received = ""
    connection.emit = { event, mock in
        if event["type"] as? String == "session.close" {
            mock.push(["type": "session.output_transcript.delta", "delta": "最后一句。"])
            mock.push(["type": "session.closed"])
        }
    }
    let client = RealtimeClient(kind: .translation) { request in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret")
        return connection
    }
    client.onEvent = { event in received += event["delta"] as? String ?? "" }
    try await client.start(key: "test-secret", language: "zh")
    client.enqueue(AudioFrame(pcm: Data(repeating: 0, count: 9600), sequence: 0))
    #expect(await client.stop())
    #expect(received == "最后一句。")
    #expect(connection.didClose)
    #expect(connection.sent.compactMap { $0["type"] as? String } == ["session.update", "session.input_audio_buffer.append", "session.close"])
}

@MainActor
@Test func transcriptionWaitsForFinalTextAfterCommit() async throws {
    let connection = MockConnection()
    connection.emit = { event, mock in
        if event["type"] as? String == "input_audio_buffer.commit" {
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                mock.push(["type": "input_audio_buffer.committed", "item_id": "a"])
                mock.push(["type": "conversation.item.input_audio_transcription.completed", "item_id": "a", "transcript": "Final source."])
            }
        }
    }
    var received = ""
    let client = RealtimeClient(kind: .transcription) { _ in connection }
    client.onEvent = { received += $0["transcript"] as? String ?? "" }
    try await client.start(key: "test-secret", language: "en")
    client.enqueue(AudioFrame(pcm: Data(repeating: 0x10, count: 9600), sequence: 0))
    #expect(await client.stop())
    #expect(received == "Final source.")
    #expect(connection.didClose)
}

@MainActor
@Test func apiErrorsNeverExposeTheKey() async {
    let connection = MockConnection()
    connection.rejectConfiguration = true
    let client = RealtimeClient(kind: .translation) { _ in connection }
    do {
        try await client.start(key: "test-secret", language: "zh")
        Issue.record("An API configuration error should fail startup.")
    } catch {
        #expect(!error.localizedDescription.contains("test-secret"))
        #expect(error.localizedDescription.contains("[redacted]"))
    }
    _ = await client.stop(gracefully: false)
    #expect(connection.didClose)
}

@MainActor
@Test func fullSendQueueFailsInsteadOfBuildingUnlimitedDelay() async throws {
    let connection = MockConnection()
    let client = RealtimeClient(kind: .translation) { _ in connection }
    var failures: [String] = []
    client.onFailure = { failures.append($0) }
    try await client.start(key: "test-secret", language: "zh")
    for index in 0..<20 {
        client.enqueue(AudioFrame(pcm: Data(repeating: 0, count: 9600), sequence: index))
    }
    #expect(failures.count == 1)
    #expect(failures.first?.contains("behind") == true)
    _ = await client.stop(gracefully: false)
    #expect(connection.didClose)
}
