@testable import BilingualLiveCaption
import AppKit
import CaptionCore
import SwiftUI
import Testing

private final class MemoryDefaults: UserDefaults {
    var values: [String: Data] = [:]
    override func data(forKey defaultName: String) -> Data? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value as? Data }
}

private final class MemoryCredentials: CredentialStore {
    var key: String?
    var writes: [String] = []
    var denied = false
    func load() throws -> String? {
        if denied { throw CaptionError("Access denied") }
        return key
    }
    func save(_ key: String) throws {
        if denied { throw CaptionError("Access denied") }
        writes.append(key)
        self.key = key.isEmpty ? nil : key
    }
}

@MainActor
@Test func settingsAndKeyRestoreWithoutResumingCapture() async throws {
    let defaults = MemoryDefaults()
    let preferences = UserPreferences(defaults: defaults)
    let credentials = MemoryCredentials()
    let first = CaptionModel(preferences: preferences, credentials: credentials, environment: [:])
    first.mode = .openAI
    first.sourceLanguage = "en-AU"
    first.targetLanguage = "ja"
    first.selectedApp = "com.apple.Safari"
    first.keywords = "sea ice"
    first.fontSize = 18
    first.translationFontSize = 32
    first.opacity = 0.4
    first.backgroundColor = .blue
    first.originalColor = .yellow
    first.translationColor = .green
    first.isOverlayVisible = true
    first.original = "Private caption"
    first.apiKey = "test-secret"
    await first.quit()

    let saved = try #require(try preferences.load())
    let restored = CaptionModel(preferences: preferences, credentials: credentials, environment: [:])
    #expect(restored.mode == .openAI)
    #expect(restored.sourceLanguage == "en-AU" && restored.targetLanguage == "ja")
    #expect(restored.selectedApp == "com.apple.Safari")
    #expect(restored.keywords == "sea ice")
    #expect(restored.fontSize == 18 && restored.translationFontSize == 32)
    #expect(restored.opacity == 0.4 && restored.isOverlayVisible)
    for (actual, expected) in [(SavedColor(restored.backgroundColor), saved.backgroundColor),
                               (SavedColor(restored.originalColor), saved.originalColor),
                               (SavedColor(restored.translationColor), saved.translationColor)] {
        #expect(abs(actual.red - expected.red) < 0.00001)
        #expect(abs(actual.green - expected.green) < 0.00001)
        #expect(abs(actual.blue - expected.blue) < 0.00001)
    }
    #expect(restored.apiKey == "test-secret")
    #expect(!restored.isRunning && !restored.isBusy && !restored.isPreview)
    #expect(restored.original.isEmpty && restored.translation.isEmpty)
    let bytes = try #require(defaults.data(forKey: UserPreferences.settingsKey))
    let json = String(decoding: bytes, as: UTF8.self)
    #expect(!json.contains("test-secret") && !json.contains("Private caption"))
    #expect(credentials.writes == ["test-secret"])
}

@MainActor
@Test func clearedKeyIsRemovedAndDeniedAccessDoesNotOverwriteIt() async {
    let credentials = MemoryCredentials()
    credentials.key = "previous-key"
    let model = CaptionModel(credentials: credentials, environment: [:])
    model.apiKey = ""
    model.saveAPIKey()
    #expect(credentials.key == nil)
    #expect(model.keychainStatus == "Saved API key removed.")

    credentials.key = "protected-key"
    credentials.denied = true
    let denied = CaptionModel(credentials: credentials, environment: [:])
    #expect(denied.keychainStatus.contains("Could not load"))
    await denied.quit()
    #expect(credentials.key == "protected-key")
    denied.apiKey = "replacement-key"
    denied.saveAPIKey()
    #expect(denied.keychainStatus.contains("not saved"))
    #expect(credentials.key == "protected-key")
}

@MainActor
@Test func incompleteSettingsDoNotPreventLaunch() {
    let defaults = MemoryDefaults()
    defaults.values[UserPreferences.settingsKey] = Data("{}".utf8)
    let model = CaptionModel(preferences: UserPreferences(defaults: defaults), environment: [:])
    #expect(model.preferencesError != nil)
    #expect(model.fontSize == 22 && !model.isRunning)
}

@MainActor
@Test func editedKeySavesAfterTypingWithoutQuitting() async throws {
    let credentials = MemoryCredentials()
    let model = CaptionModel(credentials: credentials, environment: [:])
    model.apiKey = "partial"
    model.apiKey = "complete-test-key"
    try await Task.sleep(for: .milliseconds(950))
    #expect(credentials.writes == ["complete-test-key"])
    #expect(model.keychainStatus == "API key saved in macOS Keychain.")
}
