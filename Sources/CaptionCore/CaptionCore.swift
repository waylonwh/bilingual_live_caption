import Foundation

public enum TranscriptionMode: String, CaseIterable, Identifiable, Sendable {
    case apple = "Apple on-device"
    case openAI = "OpenAI cloud"

    public var id: String { rawValue }
    public var ratePerMinute: Double { self == .apple ? 0.034 : 0.051 }
}

public struct AudioFrame: Sendable {
    public static let sampleRate = 24_000
    public static let byteCount = 9_600
    public let pcm: Data
    public let sequence: Int

    public init(pcm: Data, sequence: Int) {
        self.pcm = pcm
        self.sequence = sequence
    }

    public var duration: Double { Double(pcm.count) / 48_000 }
    public var rms: Double {
        guard pcm.count >= 2 else { return 0 }
        var sum = 0.0
        pcm.withUnsafeBytes { bytes in
            for index in stride(from: 0, to: bytes.count - 1, by: 2) {
                let bits = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
                let value = Double(Int16(bitPattern: bits)) / 32768
                sum += value * value
            }
        }
        return sqrt(sum / Double(pcm.count / 2))
    }
}

public struct AudioFramer {
    private var pending = Data()
    private var sequence = 0
    public init() {}

    public mutating func append(_ pcm: Data) -> Bool {
        pending.append(pcm)
        return pending.count <= AudioFrame.byteCount * 10
    }

    public mutating func next() -> AudioFrame {
        let count = min(pending.count, AudioFrame.byteCount)
        var data = Data(pending.prefix(count))
        pending.removeFirst(count)
        data.append(Data(repeating: 0, count: AudioFrame.byteCount - count))
        defer { sequence += 1 }
        return AudioFrame(pcm: data, sequence: sequence)
    }
}

public struct TurnBoundaryDetector {
    private var samples = 0
    private var silentSamples = 0
    private var hasSpeech = false
    public init() {}

    public mutating func append(_ frame: AudioFrame) -> Bool {
        let count = frame.pcm.count / 2
        samples += count
        if frame.rms > 0.006 {
            hasSpeech = true
            silentSamples = 0
        } else {
            silentSamples += count
        }
        if (hasSpeech && silentSamples >= 19_200) || samples >= 360_000 {
            reset()
            return true
        }
        return false
    }

    public var hasPendingAudio: Bool { samples >= 2400 }
    public mutating func reset() {
        samples = 0
        silentSamples = 0
        hasSpeech = false
    }
}

public struct TranscriptStore {
    private struct Item {
        var text: String
        var final: Bool
    }
    private var order: [String] = []
    private var items: [String: Item] = [:]
    private let limit: Int

    public init(limit: Int = 40) { self.limit = limit }

    public var text: String {
        order.compactMap { items[$0]?.text }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    public mutating func register(_ id: String, after previous: String? = nil) {
        if !order.contains(id) { order.append(id) }
        if let previous, let previousIndex = order.firstIndex(of: previous),
           let index = order.firstIndex(of: id), index <= previousIndex, id != previous {
            order.remove(at: index)
            if let position = order.firstIndex(of: previous) { order.insert(id, at: position + 1) }
        }
        trim()
    }

    public mutating func delta(id: String, text: String) {
        register(id)
        if items[id]?.final == true { return }
        var item = items[id] ?? Item(text: "", final: false)
        item.text += text
        items[id] = item
    }

    public mutating func replace(id: String, text: String, final: Bool) {
        register(id)
        if items[id]?.final == true && !final { return }
        items[id] = Item(text: text, final: final)
    }

    private mutating func trim() {
        while order.count > limit {
            items.removeValue(forKey: order.removeFirst())
        }
    }
}

public enum RealtimeProtocol {
    public enum Kind: Sendable { case translation, transcription }

    public static func url(for kind: Kind) -> URL {
        URL(string: kind == .translation
            ? "wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate"
            : "wss://api.openai.com/v1/realtime?intent=transcription")!
    }

    public static func configuration(for kind: Kind, language: String, keywords: [String] = []) -> [String: Any] {
        if kind == .translation {
            return ["type": "session.update", "session": ["audio": [
                "input": ["transcription": NSNull(), "noise_reduction": NSNull()],
                "output": ["language": language]
            ]]]
        }
        var transcription: [String: Any] = [
            "model": "gpt-live-transcribe", "languages": [language], "delay": "low"
        ]
        if !keywords.isEmpty { transcription["keywords"] = keywords }
        return ["type": "session.update", "session": ["type": "transcription", "audio": ["input": [
            "format": ["type": "audio/pcm", "rate": 24000],
            "transcription": transcription, "turn_detection": NSNull(), "noise_reduction": NSNull()
        ]]]]
    }

    public static func append(_ frame: AudioFrame, kind: Kind) -> [String: Any] {
        ["type": kind == .translation ? "session.input_audio_buffer.append" : "input_audio_buffer.append",
         "audio": frame.pcm.base64EncodedString()]
    }
}

public struct CaptionError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
