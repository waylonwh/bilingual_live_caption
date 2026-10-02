@testable import BilingualLiveCaption
import AVFoundation
import CaptionCore
import Testing

@Test(arguments: [44100.0, 48000.0], [false, true])
func systemAudioConversionPreservesDurationAndSignal(sampleRate: Double, interleaved: Bool) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                               channels: 2, interleaved: interleaved)!
    let converter = try CapturedAudioConverter(format: format)
    let frameCount = Int(sampleRate / 20)
    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
    input.frameLength = AVAudioFrameCount(frameCount)
    let channels = input.floatChannelData!
    var result = Data()
    for chunk in 0..<20 {
        for frame in 0..<frameCount {
            let sample = Float(0.25 * sin(2 * Double.pi * 440 * Double(chunk * frameCount + frame) / sampleRate))
            if interleaved {
                channels[0][frame * 2] = sample
                channels[0][frame * 2 + 1] = sample
            } else {
                channels[0][frame] = sample
                channels[1][frame] = sample
            }
        }
        result.append(try converter.convert(input.audioBufferList))
    }
    #expect(abs(result.count - 48000) < 1024)
    let level = AudioFrame(pcm: result, sequence: 0).rms
    #expect(level > 0.15 && level < 0.20)
}

@Test func systemAudioConversionHandlesSilenceAndRejectsChangedLayout() throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let converter = try CapturedAudioConverter(format: format)
    let silent = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
    silent.frameLength = 4800
    for channel in 0..<2 {
        silent.floatChannelData![channel].update(repeating: 0, count: 4800)
    }
    let result = try converter.convert(silent.audioBufferList)
    #expect(!result.isEmpty)
    #expect(result.allSatisfy { $0 == 0 })
    let changedFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let changed = AVAudioPCMBuffer(pcmFormat: changedFormat, frameCapacity: 4800)!
    changed.frameLength = 4800
    #expect(throws: CaptionError.self) { try converter.convert(changed.audioBufferList) }
}
