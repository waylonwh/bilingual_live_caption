import AppKit
import AVFoundation
import CaptionCore
import CoreAudio

struct AudioApplication: Identifiable, Hashable {
    let id: String
    let name: String
}

@MainActor
final class AudioCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var output: CaptureOutput?
    private var formatListener: AudioObjectPropertyListenerBlock?
    private let queue = DispatchQueue(label: "caption.audio.capture", qos: .userInitiated)

    static func applications() async throws -> [AudioApplication] {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil
        }
        return Dictionary(grouping: apps, by: { $0.bundleIdentifier! })
            .compactMap { id, matches in matches.first.map { AudioApplication(id: id, name: $0.localizedName ?? id) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func tapDescription(applicationID: String?, ownBundleID: String) -> CATapDescription {
        let description = CATapDescription()
        description.name = "Bilingual Live Caption Audio"
        description.uuid = UUID()
        description.isPrivate = true
        description.isMixdown = true
        description.isMono = true
        description.muteBehavior = .unmuted
        description.isExclusive = applicationID == nil
        description.bundleIDs = [applicationID ?? ownBundleID]
        description.isProcessRestoreEnabled = true
        return description
    }

    static func aggregateDescription(tapUID: String) -> [String: Any] {
        [kAudioAggregateDeviceNameKey: "Bilingual Live Caption Audio",
         kAudioAggregateDeviceUIDKey: UUID().uuidString,
         kAudioAggregateDeviceIsPrivateKey: true,
         kAudioAggregateDeviceTapAutoStartKey: false,
         kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID,
                                           kAudioSubTapDriftCompensationKey: true]]]
    }

    func prepare(applicationID: String?, onFailure: @escaping @Sendable (String) -> Void) async throws -> AsyncStream<AudioFrame> {
        guard deviceID == kAudioObjectUnknown else { throw CaptionError("Audio capture is already prepared.") }
        if let applicationID, NSRunningApplication.runningApplications(withBundleIdentifier: applicationID).isEmpty {
            throw CaptionError("The selected app has closed. Open it and start captions again.")
        }
        let ownID = Bundle.main.bundleIdentifier ?? "net.waylonwu.bilingual-live-caption"
        let description = Self.tapDescription(applicationID: applicationID, ownBundleID: ownID)
        do {
            try check(AudioHardwareCreateProcessTap(description, &tapID), operation: "Create the system audio tap")
            let format = try Self.tapFormat(tapID)
            let converter = try CapturedAudioConverter(format: format)
            let (frames, continuation) = AsyncStream<AudioFrame>.makeStream(bufferingPolicy: .bufferingOldest(10))
            let output = CaptureOutput(converter: converter, continuation: continuation, onFailure: onFailure)
            self.output = output
            try check(AudioHardwareCreateAggregateDevice(Self.aggregateDescription(tapUID: description.uuid.uuidString) as CFDictionary,
                                                        &deviceID), operation: "Prepare the audio input")
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, deviceID, queue) { _, input, _, _, _ in
                output.receive(input)
            }, operation: "Prepare the audio callback")
            let monitoredTap = tapID
            let listener: AudioObjectPropertyListenerBlock = { _, _ in
                guard let current = try? Self.tapFormat(monitoredTap), format.isEqual(current) else {
                    output.formatChanged()
                    return
                }
            }
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            try check(AudioObjectAddPropertyListenerBlock(tapID, &address, queue, listener), operation: "Monitor the audio format")
            formatListener = listener
            // Trigger system-audio permission before opening paid API sessions; discard input until start().
            try check(AudioDeviceStart(deviceID, ioProc), operation: "Start system audio capture")
            return frames
        } catch {
            cleanUp()
            throw error
        }
    }

    func start() async throws {
        guard let output, ioProc != nil else { throw CaptionError("Audio capture is not prepared.") }
        try queue.sync { try output.startClock(on: queue) }
    }

    func stop() async { cleanUp() }

    private func cleanUp() {
        if let output { queue.sync { output.finish() } }
        if let ioProc {
            AudioDeviceStop(deviceID, ioProc)
            AudioDeviceDestroyIOProcID(deviceID, ioProc)
            self.ioProc = nil
        }
        if let listener = formatListener {
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(tapID, &address, queue, listener)
            formatListener = nil
        }
        if deviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(deviceID)
            deviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        output = nil
    }

    private nonisolated static func tapFormat(_ tapID: AudioObjectID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var basic = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &basic)
        guard status == noErr else { throw CaptionError("Could not read the system audio format (\(status)).") }
        guard basic.mSampleRate > 0, basic.mChannelsPerFrame > 0, basic.mBytesPerFrame > 0,
              let format = AVAudioFormat(streamDescription: &basic) else {
            throw CaptionError("The system audio tap has no usable audio format.")
        }
        return format
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw CaptionError("\(operation) failed (\(status)). Allow system audio recording for this app in System Settings, then retry.")
        }
    }
}

final class CapturedAudioConverter {
    private let format: AVAudioFormat
    private let converter: AVAudioConverter
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!

    init(format: AVAudioFormat) throws {
        self.format = format
        guard let converter = AVAudioConverter(from: format, to: target) else {
            throw CaptionError("The system audio format could not be converted.")
        }
        self.converter = converter
    }

    func convert(_ buffers: UnsafePointer<AudioBufferList>) throws -> Data {
        guard buffers.pointee.mNumberBuffers > 0, buffers.pointee.mBuffers.mDataByteSize > 0 else { return Data() }
        let expectedBuffers = format.isInterleaved ? 1 : Int(format.channelCount)
        guard Int(buffers.pointee.mNumberBuffers) == expectedBuffers,
              let input = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: buffers, deallocator: nil) else {
            throw CaptionError("The system audio format changed. Restart captions.")
        }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 24000 / format.sampleRate)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw CaptionError("Unable to allocate an audio conversion buffer.")
        }
        var supplied = false
        var conversionError: NSError?
        let result = converter.convert(to: converted, error: &conversionError) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        guard result != .error else {
            throw CaptionError("Audio conversion failed: \(conversionError?.localizedDescription ?? "Unknown error")")
        }
        guard let bytes = converted.int16ChannelData?.pointee, converted.frameLength > 0 else { return Data() }
        return Data(bytes: bytes, count: Int(converted.frameLength) * 2)
    }
}

private final class CaptureOutput: @unchecked Sendable {
    private let converter: CapturedAudioConverter
    private let continuation: AsyncStream<AudioFrame>.Continuation
    private let onFailure: @Sendable (String) -> Void
    private var framer = AudioFramer()
    private var timer: DispatchSourceTimer?
    private var active = false
    private var finished = false
    private var failure: String?

    init(converter: CapturedAudioConverter, continuation: AsyncStream<AudioFrame>.Continuation,
         onFailure: @escaping @Sendable (String) -> Void) {
        self.converter = converter
        self.continuation = continuation
        self.onFailure = onFailure
    }

    func startClock(on queue: DispatchQueue) throws {
        if let failure { throw CaptionError(failure) }
        guard !finished else { throw CaptionError("Audio capture has stopped.") }
        active = true
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            if case .dropped = self.continuation.yield(self.framer.next()) {
                self.fail("Audio processing fell behind. Restart captions to avoid delayed subtitles.")
            }
        }
        self.timer = timer
        timer.resume()
    }

    func finish() {
        finished = true
        active = false
        timer?.cancel()
        timer = nil
        continuation.finish()
    }

    func formatChanged() {
        guard !finished else { return }
        fail("The system audio format changed. Restart captions to use the new audio device.")
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        failure = message
        finish()
        onFailure(message)
    }

    func receive(_ buffers: UnsafePointer<AudioBufferList>) {
        guard active, !finished else { return }
        do {
            let data = try converter.convert(buffers)
            if !framer.append(data) { fail("Audio capture is buffering too much audio. Restart captions.") }
        } catch { fail(error.localizedDescription) }
    }
}
