import Foundation

public struct CaptionPauseDetector {
    private var quietSamples = 0
    private var heardSpeech = false
    public init() {}

    public mutating func append(_ frame: AudioFrame) -> Bool {
        if frame.rms <= 0.006 {
            quietSamples += frame.pcm.count / 2
            return false
        }
        let boundary = heardSpeech && quietSamples >= 28_800
        heardSpeech = true
        quietSamples = 0
        return boundary
    }
}

public struct CaptionTimeGap {
    private var previousEnd: Double?
    public init(previousEnd: Double? = nil) { self.previousEnd = previousEnd }

    public mutating func beginsAfterPause(start: Double?, end: Double?) -> Bool {
        guard let start, let end, start.isFinite, end.isFinite, end >= start else {
            previousEnd = nil
            return false
        }
        let boundary = previousEnd.map { start - $0 >= 1.2 - 0.000001 } ?? false
        previousEnd = end
        return boundary
    }
}
