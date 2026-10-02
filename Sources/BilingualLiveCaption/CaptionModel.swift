import AppKit
import CaptionCore
import Combine
import Foundation
import SwiftUI

struct CaptionLanguage: Identifiable {
    let id: String
    let name: String
    var apiCode: String { id.lowercased().hasPrefix("zh") ? "zh-cn" : String(id.prefix(2)) }
    static let sources = [
        CaptionLanguage(id: "en-US", name: "English (US)"),
        CaptionLanguage(id: "en-AU", name: "English (Australia)"),
        CaptionLanguage(id: "en-GB", name: "English (UK)"),
        CaptionLanguage(id: "zh-CN", name: "Chinese (Mandarin)"),
        CaptionLanguage(id: "ja-JP", name: "Japanese"),
        CaptionLanguage(id: "fr-FR", name: "French"),
        CaptionLanguage(id: "de-DE", name: "German"),
        CaptionLanguage(id: "es-ES", name: "Spanish")
    ]
    static let targets = [
        CaptionLanguage(id: "zh", name: "Chinese"), CaptionLanguage(id: "en", name: "English"),
        CaptionLanguage(id: "ja", name: "Japanese"), CaptionLanguage(id: "fr", name: "French"),
        CaptionLanguage(id: "de", name: "German"), CaptionLanguage(id: "es", name: "Spanish"),
        CaptionLanguage(id: "ko", name: "Korean"), CaptionLanguage(id: "pt", name: "Portuguese"),
        CaptionLanguage(id: "it", name: "Italian"), CaptionLanguage(id: "ru", name: "Russian"),
        CaptionLanguage(id: "hi", name: "Hindi"), CaptionLanguage(id: "id", name: "Indonesian"),
        CaptionLanguage(id: "vi", name: "Vietnamese")
    ]
}

@MainActor
final class CaptionModel: ObservableObject {
    @Published var mode: TranscriptionMode = .apple { didSet { savePreferences() } }
    @Published var apiKey = "" { didSet { scheduleKeySave() } }
    @Published var sourceLanguage = "en-US" { didSet { updateOriginalCaption(); savePreferences() } }
    @Published var targetLanguage = "zh" { didSet { updateTranslationCaption(); savePreferences() } }
    @Published var keywords = "" { didSet { savePreferences() } }
    @Published var selectedApp = "" { didSet { savePreferences() } }
    @Published var applications: [AudioApplication] = []
    var original = "" { didSet { updateOriginalCaption() } }
    var translation = "" { didSet { updateTranslationCaption() } }
    @Published private(set) var originalCaption = ""
    @Published private(set) var translationCaption = ""
    @Published var status = "Ready"
    @Published var error: String?
    @Published var isRunning = false
    @Published var isBusy = false
    @Published var isSwitching = false
    @Published var isPreview = false
    @Published var isInstalling = false
    @Published var appleStatus = "Check the local language model before starting."
    @Published var appleInstalled = false
    @Published var downloadFraction = 0.0
    @Published var fontSize = 22.0 { didSet { savePreferences() } }
    @Published var translationFontSize = 22.0 { didSet { savePreferences() } }
    @Published var backgroundColor = Color.black { didSet { savePreferences() } }
    @Published var originalColor = Color.white { didSet { savePreferences() } }
    @Published var translationColor = Color.white { didSet { savePreferences() } }
    @Published var opacity = 0.7 { didSet { savePreferences() } }
    @Published var isOverlayVisible = false { didSet { savePreferences() } }
    @Published var preferencesError: String?
    @Published var keychainStatus = "API key stays in memory."
    @Published var level = 0.0
    @Published var elapsed = 0.0
    @Published var estimatedCost = 0.0
    @Published var lastOriginal: Date?
    @Published var lastTranslation: Date?
    var showOverlay: (() -> Void)?
    var hideOverlay: (() -> Void)?
    private var capture: AudioCapture?
    private var translator: RealtimeClient?
    private var cloudTranscriber: RealtimeClient?
    private var appleTranscriber: AppleTranscriber?
    private var pendingCloud: RealtimeClient?
    private var pendingApple: AppleTranscriber?
    private var audioTask: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var runID = UUID()
    private var transcriptionID = UUID()
    private var store = TranscriptStore()
    private let originalFormatter = SentenceFormatter()
    private let translationFormatter = SentenceFormatter()
    private var activeKey = ""
    private var stopping = false
    private let preferences: PreferencesStore?
    private let credentials: CredentialStore?
    private var readyToSave = false
    private var lastSavedKey = ""
    private var keySaveTask: Task<Void, Never>?

    init(preferences: PreferencesStore? = nil, credentials: CredentialStore? = nil,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.preferences = preferences
        self.credentials = credentials
        do {
            if let saved = try preferences?.load() {
                mode = TranscriptionMode(rawValue: saved.mode) ?? .apple
                if CaptionLanguage.sources.contains(where: { $0.id == saved.sourceLanguage }) { sourceLanguage = saved.sourceLanguage }
                if CaptionLanguage.targets.contains(where: { $0.id == saved.targetLanguage }) { targetLanguage = saved.targetLanguage }
                keywords = saved.keywords
                selectedApp = saved.selectedApp
                fontSize = min(48, max(12, saved.fontSize))
                translationFontSize = min(48, max(12, saved.translationFontSize))
                backgroundColor = saved.backgroundColor.color
                originalColor = saved.originalColor.color
                translationColor = saved.translationColor.color
                opacity = min(1, max(0, saved.opacity))
                isOverlayVisible = saved.isOverlayVisible
            }
        } catch { preferencesError = "Saved settings could not be loaded. \(error.localizedDescription)" }
        do {
            let stored = try credentials?.load()
            apiKey = stored ?? environment["OPENAI_API_KEY"] ?? ""
            lastSavedKey = stored ?? ""
            if credentials != nil {
                keychainStatus = stored != nil ? "API key loaded from macOS Keychain." :
                    apiKey.isEmpty ? "Enter a key to save it in macOS Keychain." : "Environment key — click Save to keep it in Keychain."
            }
        } catch {
            keychainStatus = "Could not load the API key. \(error.localizedDescription)"
        }
        readyToSave = true
    }

    func savePreferences() {
        guard readyToSave, let preferences else { return }
        do {
            try preferences.save(SavedSettings(mode: mode.rawValue, sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage, keywords: keywords, selectedApp: selectedApp,
                fontSize: fontSize, translationFontSize: translationFontSize,
                backgroundColor: SavedColor(backgroundColor), originalColor: SavedColor(originalColor),
                translationColor: SavedColor(translationColor), opacity: opacity, isOverlayVisible: isOverlayVisible))
            preferencesError = nil
        } catch { preferencesError = "Settings could not be saved. \(error.localizedDescription)" }
    }

    private func scheduleKeySave() {
        guard readyToSave, credentials != nil else { return }
        keySaveTask?.cancel()
        keychainStatus = "Saving API key…"
        keySaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(700)) }
            catch { return }
            self?.saveAPIKey()
        }
    }

    func saveAPIKey() {
        guard let credentials else { return }
        keySaveTask?.cancel()
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key != lastSavedKey else {
            keychainStatus = key.isEmpty ? "No saved API key." : "API key is unchanged."
            return
        }
        do {
            try credentials.save(key)
            lastSavedKey = key
            keychainStatus = key.isEmpty ? "Saved API key removed." : "API key saved in macOS Keychain."
        } catch { keychainStatus = "API key was not saved. \(safeMessage(error.localizedDescription))" }
    }

    var canConfigure: Bool { !isRunning && !isBusy && !isInstalling }
    var sourceAPI: String { CaptionLanguage.sources.first { $0.id == sourceLanguage }?.apiCode ?? "en" }
    var parsedKeywords: [String] {
        keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    func refreshApplications() {
        operation = Task { [self] in
            isBusy = true
            defer { isBusy = false }
            do { applications = try await AudioCapture.applications() }
            catch { self.error = "Could not list audio sources. \(error.localizedDescription)" }
        }
    }

    func checkAppleModel() async {
        let language = sourceLanguage
        do {
            let installed = try await AppleTranscriber.isInstalled(language: language)
            guard language == sourceLanguage else { return }
            appleInstalled = installed
            appleStatus = installed ? "Local language model is ready." : "Prepare the local language model. A download may be needed."
        } catch {
            guard language == sourceLanguage else { return }
            appleInstalled = false
            appleStatus = error.localizedDescription
        }
    }

    func downloadAppleModel() {
        guard canConfigure else { return }
        isInstalling = true
        error = nil
        operation = Task { [self] in
            var progressTask: Task<Void, Never>?
            defer { progressTask?.cancel(); isInstalling = false }
            do {
                try await AppleTranscriber.install(language: sourceLanguage) { progress in
                    progressTask = Task {
                        while !Task.isCancelled {
                            self.downloadFraction = progress.fractionCompleted
                            try? await Task.sleep(for: .milliseconds(250))
                        }
                    }
                }
                await checkAppleModel()
            } catch { self.error = "Apple model download failed: \(error.localizedDescription)" }
        }
    }

    func start() {
        guard canConfigure else { return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { error = "Enter your OpenAI API key to start translation."; return }
        guard !parsedKeywords.contains(where: { $0.contains("<") || $0.contains(">") || $0.contains("\n") || $0.contains("\r") }) else {
            error = "Keywords must be single-line terms without < or >. Separate terms with commas."
            return
        }
        endPreview()
        clearCaptions()
        error = nil
        isBusy = true
        status = "Preparing…"
        activeKey = key
        let id = UUID()
        runID = id
        operation = Task { [self] in
            do {
                if mode == .apple {
                    guard try await AppleTranscriber.isInstalled(language: sourceLanguage) else {
                        throw CaptionError("Use Prepare Apple Model first, or choose OpenAI cloud transcription.")
                    }
                }
                try Task.checkCancellation()
                let capture = AudioCapture()
                self.capture = capture
                let frames = try await capture.prepare(applicationID: selectedApp.isEmpty ? nil : selectedApp) { [weak self] message in
                    Task { @MainActor in self?.handleFailure(message, run: id) }
                }
                try Task.checkCancellation()
                status = "Connecting translation…"
                let translator = RealtimeClient(kind: .translation)
                self.translator = translator
                translator.onEvent = { [weak self] event in
                    guard let self, self.runID == id else { return }
                    if event["type"] as? String == "session.output_transcript.delta", let delta = event["delta"] as? String {
                        self.translation = String((self.translation + delta).suffix(6000))
                        self.lastTranslation = Date()
                    }
                }
                translator.onFailure = { [weak self] in self?.handleFailure($0, run: id) }
                try await translator.start(key: key, language: targetLanguage)
                status = "Preparing transcription…"
                try await prepareTranscriber(mode, run: id)
                try Task.checkCancellation()
                try await capture.start()
                try Task.checkCancellation()
                isRunning = true
                isBusy = false
                status = "Listening"
                showOverlay?()
                audioTask = Task {
                    for await frame in frames {
                        guard self.runID == id, self.isRunning else { return }
                        self.translator?.enqueue(frame)
                        self.cloudTranscriber?.enqueue(frame)
                        do { try self.appleTranscriber?.enqueue(frame) }
                        catch { self.handleFailure(error.localizedDescription, run: id); return }
                        self.level = min(1, frame.rms * 8)
                        self.elapsed += frame.duration
                        self.estimatedCost += frame.duration / 60 * self.mode.ratePerMinute
                    }
                }
            } catch {
                if Task.isCancelled { return }
                guard runID == id else { return }
                self.error = safeMessage(error.localizedDescription)
                await shutdown(gracefully: false)
            }
        }
    }

    func changeMode(_ requested: TranscriptionMode) {
        guard requested != mode, !isBusy, !isSwitching, !isInstalling else { return }
        if !isRunning { mode = requested; return }
        isSwitching = true
        error = nil
        status = "Switching transcription…"
        let id = runID
        operation = Task {
            do {
                try await prepareTranscriber(requested, run: id)
                guard runID == id, isRunning, !stopping, !Task.isCancelled else { return }
                mode = requested
                status = "Listening"
            } catch {
                if runID == id, isRunning, !stopping, !Task.isCancelled {
                    self.error = safeMessage("Could not switch. The previous mode is still active. \(error.localizedDescription)")
                    status = "Listening"
                }
            }
            isSwitching = false
        }
    }

    private func prepareTranscriber(_ requested: TranscriptionMode, run id: UUID) async throws {
        let token = UUID()
        do {
            if requested == .apple {
                let local = AppleTranscriber()
                pendingApple = local
                local.onText = { [weak self] item, text, final in
                    guard let self, self.runID == id, self.transcriptionID == token else { return }
                    self.store.replace(id: "\(token)-\(item)", text: text, final: final)
                    self.updateOriginal()
                }
                local.onFailure = { [weak self] message in
                    guard self?.transcriptionID == token else { return }
                    self?.handleFailure(message, run: id)
                }
                try await local.start(language: sourceLanguage, keywords: parsedKeywords)
            } else {
                let cloud = RealtimeClient(kind: .transcription)
                pendingCloud = cloud
                cloud.onEvent = { [weak self] event in
                    guard let self, self.runID == id, self.transcriptionID == token,
                          let item = event["item_id"] as? String else { return }
                    let itemID = "\(token)-\(item)"
                    switch event["type"] as? String {
                    case "input_audio_buffer.committed":
                        let previous = (event["previous_item_id"] as? String).map { "\(token)-\($0)" }
                        self.store.register(itemID, after: previous)
                    case "conversation.item.input_audio_transcription.delta":
                        self.store.delta(id: itemID, text: event["delta"] as? String ?? "")
                    case "conversation.item.input_audio_transcription.completed":
                        self.store.replace(id: itemID, text: event["transcript"] as? String ?? "", final: true)
                    default: return
                    }
                    self.updateOriginal()
                }
                cloud.onFailure = { [weak self] message in
                    guard self?.transcriptionID == token else { return }
                    self?.handleFailure(message, run: id)
                }
                try await cloud.start(key: activeKey, language: sourceAPI, keywords: parsedKeywords)
            }
            try Task.checkCancellation()
            guard runID == id else { throw CancellationError() }
            let oldCloud = cloudTranscriber
            let oldApple = appleTranscriber
            transcriptionID = token
            cloudTranscriber = pendingCloud
            appleTranscriber = pendingApple
            pendingCloud = nil
            pendingApple = nil
            // Keep the translation stream and capture clock running during a switch.
            _ = await oldCloud?.stop(gracefully: false)
            await oldApple?.stop()
        } catch {
            _ = await pendingCloud?.stop(gracefully: false)
            await pendingApple?.stop()
            pendingCloud = nil
            pendingApple = nil
            throw error
        }
    }

    func stop() {
        guard !stopping else { return }
        if isPreview { endPreview(); return }
        guard isRunning || isBusy || isSwitching else { return }
        operation?.cancel()
        operation = Task { await shutdown(gracefully: true) }
    }

    private func shutdown(gracefully: Bool) async {
        guard !stopping else { return }
        stopping = true
        defer { stopping = false }
        isRunning = false
        isBusy = true
        status = "Stopping…"
        audioTask?.cancel()
        audioTask = nil
        async let captureStopped: Void = capture?.stop() ?? ()
        _ = await pendingCloud?.stop(gracefully: false)
        await pendingApple?.stop()
        pendingCloud = nil
        pendingApple = nil
        async let translationDrained = translator?.stop(gracefully: gracefully)
        async let sourceDrained = cloudTranscriber?.stop(gracefully: gracefully)
        await appleTranscriber?.stop(gracefully: gracefully)
        let drained = await (translationDrained, sourceDrained)
        await captureStopped
        capture = nil
        if gracefully && (drained.0 == false || drained.1 == false) && error == nil {
            error = "Stopped. Some final words may be missing because the connection did not finish draining."
        }
        translator = nil
        cloudTranscriber = nil
        appleTranscriber = nil
        activeKey = ""
        runID = UUID()
        isBusy = false
        isSwitching = false
        level = 0
        status = error == nil ? "Stopped" : "Stopped — check the message below"
    }

    private func handleFailure(_ message: String, run id: UUID) {
        guard runID == id, !isBusy || isRunning else { return }
        error = safeMessage(message)
        operation?.cancel()
        operation = Task { await shutdown(gracefully: false) }
    }

    private func safeMessage(_ message: String) -> String {
        let key = activeKey.isEmpty ? apiKey : activeKey
        return key.isEmpty ? message : message.replacingOccurrences(of: key, with: "[redacted]")
    }

    private func updateOriginalCaption() {
        originalCaption = originalFormatter.format(original, language: sourceLanguage)
    }

    private func updateTranslationCaption() {
        translationCaption = translationFormatter.format(translation, language: targetLanguage)
    }

    private func updateOriginal() {
        original = String(store.text.suffix(6000))
        lastOriginal = Date()
    }

    func clearCaptions() {
        store = TranscriptStore()
        original = ""
        translation = ""
        lastOriginal = nil
        lastTranslation = nil
        if !isRunning { elapsed = 0; estimatedCost = 0 }
    }

    func preview() {
        guard canConfigure else { return }
        clearCaptions()
        isPreview = true
        status = "Preview — no audio capture or API calls"
        showOverlay?()
        previewTask = Task {
            let source = "Ocean waves carry energy into the marginal ice zone. The captions update as the speaker continues."
            let target = "海浪将能量带入边缘冰区。说话继续时，双语字幕也会实时更新。"
            for word in source.split(separator: " ") {
                guard !Task.isCancelled else { return }
                original += (original.isEmpty ? "" : " ") + word
                lastOriginal = Date()
                try? await Task.sleep(for: .milliseconds(130))
            }
            for character in target {
                guard !Task.isCancelled else { return }
                translation.append(character)
                lastTranslation = Date()
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
    }

    func endPreview() {
        previewTask?.cancel()
        previewTask = nil
        isPreview = false
        status = "Ready"
    }

    func quit() async {
        savePreferences()
        saveAPIKey()
        operation?.cancel()
        endPreview()
        await shutdown(gracefully: false)
    }
}
