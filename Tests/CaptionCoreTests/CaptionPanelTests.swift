@testable import BilingualLiveCaption
import AppKit
import SwiftUI
import Testing

@MainActor
private final class RecordingCaptionPanel: CaptionPanel {
    var dragLocations: [NSPoint] = []
    override func makeKey() {}
    override func performDrag(with event: NSEvent) { dragLocations.append(event.locationInWindow) }
}

@MainActor
@Test func captionClicksReachWindowDraggingBeforeScrollViews() throws {
    _ = NSApplication.shared
    let panel = RecordingCaptionPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 140),
                                      styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    defer { panel.close() }
    let model = CaptionModel()
    model.original = "Original text"
    model.translation = "Translated text"
    panel.contentView = NSHostingView(rootView: OverlayView(model: model))
    panel.contentView?.layoutSubtreeIfNeeded()
    let locations = [NSPoint(x: 40, y: 30), NSPoint(x: 40, y: 100), NSPoint(x: 690, y: 70)]
    for location in locations {
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
            modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        panel.sendEvent(event)
    }
    #expect(panel.dragLocations == locations)
    #expect(!panel.styleMask.contains(.titled))
    #expect(panel.standardWindowButton(.closeButton) == nil)
    var dismissals = 0
    panel.onDismiss = { dismissals += 1 }
    panel.cancelOperation(nil)
    panel.performClose(nil)
    #expect(dismissals == 2)
}
