import AppKit
import CaptionCore
import SwiftUI

struct SavedColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double

    init(_ color: Color) {
        let value = NSColor(color).usingColorSpace(.sRGB) ?? .white
        red = value.redComponent
        green = value.greenComponent
        blue = value.blueComponent
    }

    var color: Color { Color(red: red, green: green, blue: blue) }
}

struct SavedSettings: Codable, Equatable {
    var mode: String
    var sourceLanguage: String
    var targetLanguage: String
    var keywords: String
    var selectedApp: String
    var fontSize: Double
    var translationFontSize: Double
    var backgroundColor: SavedColor
    var originalColor: SavedColor
    var translationColor: SavedColor
    var opacity: Double
    var isOverlayVisible: Bool
}

protocol PreferencesStore {
    func load() throws -> SavedSettings?
    func save(_ settings: SavedSettings) throws
}

struct UserPreferences: PreferencesStore {
    let defaults: UserDefaults
    static let settingsKey = "captionSettings.v1"

    func load() throws -> SavedSettings? {
        guard let data = defaults.data(forKey: Self.settingsKey) else { return nil }
        return try JSONDecoder().decode(SavedSettings.self, from: data)
    }

    func save(_ settings: SavedSettings) throws {
        defaults.set(try JSONEncoder().encode(settings), forKey: Self.settingsKey)
    }
}
