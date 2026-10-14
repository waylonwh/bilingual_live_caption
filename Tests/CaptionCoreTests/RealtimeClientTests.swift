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
    client.recordingOffset = 120
    var range: (Double, Double)?
    client.onEvent = {
        received += $0["transcript"] as? String ?? ""
        if $0["type"] as? String == "conversation.item.input_audio_transcription.completed",
           let start = $0["recording_start"] as? Double, let end = $0["recording_end"] as? Double {
            range = (start, end)
        }
    }
    try await client.start(key: "test-secret", language: "en")
    client.enqueue(AudioFrame(pcm: Data(repeating: 0x10, count: 9600), sequence: 0))
    #expect(await client.stop())
    #expect(received == "Final source.")
    #expect(range?.0 == 120 && range?.1 == 120.2)
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

@MainActor
private func waitForConnectionChange(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(7)
    while !condition() {
        guard Date() < deadline else { throw CaptionError("Connection change timed out") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
@Test func translationPauseNeedsAudioEvidenceInsteadOfMessageTiming() async throws {
    let connection = MockConnection()
    let client = RealtimeClient(kind: .translation) { _ in connection }
    var breaks: [Bool] = []
    client.onEvent = { event in
        if event["type"] as? String == "session.output_transcript.delta" { breaks.append(event["caption_break"] as? Bool ?? false) }
    }
    try await client.start(key: "test-secret", language: "zh")
    connection.push(["type": "session.output_transcript.delta", "delta": "上一句", "elapsed_ms": 0])
    connection.push(["type": "session.output_transcript.delta", "delta": "继续", "elapsed_ms": 3000])
    connection.push(["type": "session.output_audio.delta", "delta": Data(repeating: 0x10, count: 9600).base64EncodedString(), "elapsed_ms": 3000])
    connection.push(["type": "session.output_audio.delta", "delta": Data(repeating: 0, count: 57600).base64EncodedString(), "elapsed_ms": 3200])
    connection.push(["type": "session.output_audio.delta", "delta": Data(repeating: 0x10, count: 9600).base64EncodedString(), "elapsed_ms": 4400])
    connection.push(["type": "session.output_transcript.delta", "delta": "。", "elapsed_ms": 4400])
    connection.push(["type": "session.output_transcript.delta", "delta": "好吧", "elapsed_ms": 4600])
    connection.push(["type": "session.output_transcript.delta", "delta": "继续", "elapsed_ms": 4800])
    try await waitForConnectionChange { breaks.count == 5 }
    #expect(breaks == [false, false, false, true, false])
    _ = await client.stop(gracefully: false)
}

@MainActor
@Test func cloudPauseBreakIsAttachedToTheNextSpeechTurn() async throws {
    let connection = MockConnection()
    var commits = 0
    connection.emit = { event, mock in
        if event["type"] as? String == "input_audio_buffer.commit" {
            commits += 1
            mock.push(["type": "input_audio_buffer.committed", "item_id": "item-\(commits)"])
            mock.push(["type": "conversation.item.input_audio_transcription.completed", "item_id": "item-\(commits)", "transcript": "Words"])
        }
    }
    let client = RealtimeClient(kind: .transcription) { _ in connection }
    var breaks: [Bool] = []
    client.onEvent = { event in
        if event["type"] as? String == "input_audio_buffer.committed" { breaks.append(event["caption_break"] as? Bool ?? false) }
    }
    try await client.start(key: "test-secret", language: "en")
    for (sequence, speech) in ([true] + Array(repeating: false, count: 6) + [true] + Array(repeating: false, count: 4)).enumerated() {
        client.enqueue(AudioFrame(pcm: Data(repeating: speech ? 0x10 : 0, count: 9600), sequence: sequence))
        try await Task.sleep(for: .milliseconds(10))
    }
    try await waitForConnectionChange { breaks.count == 2 }
    #expect(breaks == [false, true])
    #expect(await client.stop())
}

@MainActor
@Test func expiringTranslationRenewsAndPreservesFinalTextOrder() async throws {
    let old = MockConnection()
    old.push(["type": "session.updated", "session": ["expires_at": Date().addingTimeInterval(30).timeIntervalSince1970]])
    let next = MockConnection()
    old.emit = { event, mock in
        if event["type"] as? String == "session.close" {
            next.push(["type": "session.output_transcript.delta", "delta": "New."])
            mock.push(["type": "session.output_transcript.delta", "delta": "Old final."])
            mock.push(["type": "session.closed"])
        }
    }
    var connections = [old, next]
    var received = ""
    var statuses: [String] = []
    var failures: [String] = []
    let stream = RealtimeStream(kind: .translation, makeClient: {
        let connection = connections.removeFirst()
        return RealtimeClient(kind: .translation) { _ in connection }
    })
    stream.onEvent = { received += $0["delta"] as? String ?? "" }
    stream.onStatus = { statuses.append($0) }
    stream.onFailure = { failures.append($0) }
    try await stream.start(key: "test-secret", language: "zh")
    try await waitForConnectionChange { statuses.last == "Listening" }
    #expect(received == "Old final.New.")
    #expect(old.didClose)
    #expect(!next.didClose)
    #expect(failures.isEmpty)
    stream.enqueue(AudioFrame(pcm: Data(repeating: 0, count: 9600), sequence: 1))
    try await waitForConnectionChange { next.sent.contains { $0["type"] as? String == "session.input_audio_buffer.append" } }
    _ = await stream.stop(gracefully: false)
    #expect(next.didClose)
}

@MainActor
@Test func unexpectedClosureReconnectsWithoutClearingCaptions() async throws {
    let old = MockConnection()
    let next = MockConnection()
    var connections = [old, next]
    var received = ""
    var statuses: [String] = []
    var times: [Double] = []
    let stream = RealtimeStream(kind: .translation, makeClient: {
        let connection = connections.removeFirst()
        return RealtimeClient(kind: .translation) { _ in connection }
    })
    stream.onEvent = {
        received += $0["delta"] as? String ?? ""
        if let time = $0["recording_time"] as? Double { times.append(time) }
    }
    stream.onStatus = { statuses.append($0) }
    try await stream.start(key: "test-secret", language: "zh")
    stream.audioTime = 120
    stream.enqueue(AudioFrame(pcm: Data(repeating: 0, count: 9600), sequence: 0))
    old.push(["type": "session.output_transcript.delta", "delta": "Before.", "elapsed_ms": 200])
    old.push(["type": "session.closed"])
    try await waitForConnectionChange { statuses.last == "Listening" }
    stream.enqueue(AudioFrame(pcm: Data(repeating: 0, count: 9600), sequence: 1))
    next.push(["type": "session.output_transcript.delta", "delta": "After.", "elapsed_ms": 200])
    try await waitForConnectionChange { received == "Before.After." }
    #expect(old.didClose)
    #expect(times.count == 2)
    #expect(abs(times[0] - 120.2) < 0.0001 && abs(times[1] - 120.4) < 0.0001)
    _ = await stream.stop(gracefully: false)
}

@MainActor
@Test func replacementConfigurationErrorDoesNotRetryOrExposeKey() async throws {
    let old = MockConnection()
    let next = MockConnection()
    next.rejectConfiguration = true
    var created = 0
    var failures: [String] = []
    let stream = RealtimeStream(kind: .translation, makeClient: {
        created += 1
        return RealtimeClient(kind: .translation) { _ in created == 1 ? old : next }
    })
    stream.onFailure = { failures.append($0) }
    try await stream.start(key: "test-secret", language: "zh")
    old.push(["type": "session.closed"])
    try await waitForConnectionChange { !failures.isEmpty }
    #expect(created == 2)
    #expect(!failures[0].contains("test-secret"))
    #expect(next.didClose)
    _ = await stream.stop(gracefully: false)
}

@MainActor
@Test func stopCancelsPendingReplacement() async throws {
    let old = MockConnection()
    let next = MockConnection()
    next.events = []
    var created = 0
    var failures: [String] = []
    let stream = RealtimeStream(kind: .translation, makeClient: {
        created += 1
        return RealtimeClient(kind: .translation) { _ in created == 1 ? old : next }
    })
    stream.onFailure = { failures.append($0) }
    try await stream.start(key: "test-secret", language: "zh")
    old.push(["type": "session.closed"])
    try await waitForConnectionChange { created == 2 }
    _ = await stream.stop(gracefully: false)
    try await Task.sleep(for: .milliseconds(100))
    #expect(old.didClose)
    #expect(next.didClose)
    #expect(created == 2)
    #expect(failures.isEmpty)
}

@MainActor
@Test func reconnectionStopsAfterThreeTransportFailures() async throws {
    let old = MockConnection()
    var replacements: [MockConnection] = []
    var failures: [String] = []
    var created = 0
    let stream = RealtimeStream(kind: .translation, makeClient: {
        created += 1
        if created == 1 { return RealtimeClient(kind: .translation) { _ in old } }
        let connection = MockConnection()
        connection.events = []
        connection.didClose = true
        replacements.append(connection)
        return RealtimeClient(kind: .translation) { _ in connection }
    })
    stream.onFailure = { failures.append($0) }
    try await stream.start(key: "test-secret", language: "zh")
    old.close()
    try await waitForConnectionChange { !failures.isEmpty }
    #expect(replacements.count == 3)
    #expect(failures.count == 1)
    _ = await stream.stop(gracefully: false)
}

@MainActor
@Test func healthyHandoffWaitsForQuietAndNeverSendsAFrameTwice() async throws {
    let old = MockConnection()
    let next = MockConnection()
    old.emit = { event, mock in
        if event["type"] as? String == "session.close" { mock.push(["type": "session.closed"]) }
    }
    var clients: [RealtimeClient] = []
    let stream = RealtimeStream(kind: .translation, makeClient: {
        let connection = clients.isEmpty ? old : next
        let client = RealtimeClient(kind: .translation) { _ in connection }
        clients.append(client)
        return client
    })
    try await stream.start(key: "test-secret", language: "zh")
    let speech = AudioFrame(pcm: Data(repeating: 0x10, count: 9600), sequence: 0)
    stream.enqueue(speech)
    clients[0].onReconnectNeeded?("Test renewal")
    try await waitForConnectionChange { clients.count == 2 && clients[1].isAvailable }
    #expect(!old.sent.contains { $0["type"] as? String == "session.close" })
    for sequence in 1...4 {
        stream.enqueue(AudioFrame(pcm: Data(repeating: 0, count: 9600), sequence: sequence))
        try await Task.sleep(for: .milliseconds(10))
    }
    try await waitForConnectionChange { old.didClose }
    let newSpeech = AudioFrame(pcm: Data(repeating: 0x20, count: 9600), sequence: 5)
    stream.enqueue(newSpeech)
    try await waitForConnectionChange { next.sent.contains { $0["type"] as? String == "session.input_audio_buffer.append" } }
    let oldAudio = old.sent.filter { $0["type"] as? String == "session.input_audio_buffer.append" }
    let newAudio = next.sent.filter { $0["type"] as? String == "session.input_audio_buffer.append" }
    #expect(oldAudio.count == 5)
    #expect(newAudio.count == 1)
    #expect(oldAudio.first?["audio"] as? String == speech.pcm.base64EncodedString())
    #expect(newAudio.first?["audio"] as? String == newSpeech.pcm.base64EncodedString())
    _ = await stream.stop(gracefully: false)
}

@MainActor
@Test func continuousSpeechHandoffIsBoundedAndDrainsPendingTranscription() async throws {
    let old = MockConnection()
    let next = MockConnection()
    for (connection, text) in [(old, "Old final."), (next, "New final.")] {
        connection.emit = { event, mock in
            if event["type"] as? String == "input_audio_buffer.commit" {
                mock.push(["type": "conversation.item.input_audio_transcription.completed", "item_id": text, "transcript": text])
            }
        }
    }
    var clients: [RealtimeClient] = []
    var received = ""
    let stream = RealtimeStream(kind: .transcription, makeClient: {
        let connection = clients.isEmpty ? old : next
        let client = RealtimeClient(kind: .transcription) { _ in connection }
        clients.append(client)
        return client
    })
    stream.onEvent = { received += $0["transcript"] as? String ?? "" }
    try await stream.start(key: "test-secret", language: "en")
    stream.enqueue(AudioFrame(pcm: Data(repeating: 0x10, count: 9600), sequence: 0))
    clients[0].onReconnectNeeded?("Test renewal")
    try await waitForConnectionChange { clients.count == 2 && clients[1].isAvailable }
    #expect(!old.didClose)
    try await waitForConnectionChange { old.didClose }
    #expect(received == "Old final.")
    stream.enqueue(AudioFrame(pcm: Data(repeating: 0x20, count: 9600), sequence: 1))
    #expect(await stream.stop())
    #expect(received == "Old final.New final.")
}

@MainActor
@Test func stoppingDuringHandoffPreservesBufferedAndFinalTranslation() async throws {
    let old = MockConnection()
    let next = MockConnection()
    old.emit = { event, mock in
        if event["type"] as? String == "session.close" {
            next.push(["type": "session.output_transcript.delta", "delta": "New buffered."])
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                mock.push(["type": "session.output_transcript.delta", "delta": "Old final."])
                mock.push(["type": "session.closed"])
            }
        }
    }
    next.emit = { event, mock in
        if event["type"] as? String == "session.close" {
            mock.push(["type": "session.output_transcript.delta", "delta": "New final."])
            mock.push(["type": "session.closed"])
        }
    }
    var clients: [RealtimeClient] = []
    var received = ""
    let stream = RealtimeStream(kind: .translation, makeClient: {
        let connection = clients.isEmpty ? old : next
        let client = RealtimeClient(kind: .translation) { _ in connection }
        clients.append(client)
        return client
    })
    stream.onEvent = { received += $0["delta"] as? String ?? "" }
    try await stream.start(key: "test-secret", language: "zh")
    clients[0].onReconnectNeeded?("Test renewal")
    try await waitForConnectionChange { old.sent.contains { $0["type"] as? String == "session.close" } }
    #expect(!old.didClose)
    stream.enqueue(AudioFrame(pcm: Data(repeating: 0, count: 9600), sequence: 0))
    #expect(await stream.stop())
    #expect(received == "Old final.New buffered.New final.")
    #expect(old.didClose)
    #expect(next.didClose)
}

@MainActor
@Test func failedReplacementNeverTakesAudioFromHealthySession() async throws {
    let old = MockConnection()
    let failed = MockConnection()
    let next = MockConnection()
    old.emit = { event, mock in
        if event["type"] as? String == "session.close" { mock.push(["type": "session.closed"]) }
    }
    var clients: [RealtimeClient] = []
    var connections = [old, failed, next]
    let stream = RealtimeStream(kind: .translation, makeClient: {
        let connection = connections.removeFirst()
        let client = RealtimeClient(kind: .translation) { _ in connection }
        clients.append(client)
        return client
    })
    try await stream.start(key: "test-secret", language: "zh")
    stream.enqueue(AudioFrame(pcm: Data(repeating: 0x10, count: 9600), sequence: 0))
    clients[0].onReconnectNeeded?("Test renewal")
    try await waitForConnectionChange { clients.count == 2 && clients[1].isAvailable }
    failed.push(["type": "session.closed"])
    try await waitForConnectionChange { clients.count == 3 && clients[2].isAvailable }
    #expect(!old.didClose)
    #expect(failed.didClose)
    #expect(!failed.sent.contains { $0["type"] as? String == "session.input_audio_buffer.append" })
    for sequence in 1...4 {
        stream.enqueue(AudioFrame(pcm: Data(repeating: 0, count: 9600), sequence: sequence))
        try await Task.sleep(for: .milliseconds(10))
    }
    try await waitForConnectionChange { old.didClose }
    _ = await stream.stop(gracefully: false)
}
