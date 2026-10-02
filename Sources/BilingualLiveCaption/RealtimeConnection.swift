import Foundation

@MainActor
protocol RealtimeConnection: AnyObject {
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func close()
}

@MainActor
final class OpenAIConnection: RealtimeConnection {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask

    init(request: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 4 * 1024 * 1024
        socket.resume()
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws { try await socket.send(message) }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await socket.receive() }
    func close() {
        socket.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}
