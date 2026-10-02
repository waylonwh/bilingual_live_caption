import AppKit
import CaptionCore
import SwiftUI

@MainActor
enum PreviewRenderer {
    static func render(to directory: String) throws {
        _ = NSApplication.shared
        let model = CaptionModel()
        model.apiKey = ""
        model.appleStatus = "Local language model is ready."
        model.appleInstalled = true
        model.original = "Ocean waves carry energy into the marginal ice zone. The captions update as the speaker continues."
        model.translation = "海浪将能量带入边缘冰区。说话继续时，双语字幕也会实时更新。"
        model.isPreview = true
        model.status = "Preview — no audio capture or API calls"
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try save(ControlsView(model: model), size: NSSize(width: 610, height: 780), to: folder.appendingPathComponent("controls.png"))
        try save(OverlayView(model: model), size: NSSize(width: 720, height: 140), to: folder.appendingPathComponent("captions.png"))
        try save(OverlayView(model: model), size: NSSize(width: 720, height: 240), to: folder.appendingPathComponent("captions-sentences.png"))
        model.mode = .openAI
        try save(ControlsView(model: model), size: NSSize(width: 610, height: 780), to: folder.appendingPathComponent("controls-cloud.png"))
        model.fontSize = 20
        model.translationFontSize = 30
        try save(OverlayView(model: model), size: NSSize(width: 720, height: 180), to: folder.appendingPathComponent("captions-proportional.png"))
    }

    private static func save<Content: View>(_ content: Content, size: NSSize, to url: URL) throws {
        let view = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CaptionError("Could not allocate a preview image.")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CaptionError("Could not encode a preview image.")
        }
        try data.write(to: url)
        window.close()
    }
}
