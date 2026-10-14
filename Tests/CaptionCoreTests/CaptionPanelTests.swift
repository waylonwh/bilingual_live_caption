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

@MainActor
@Test func captionWindowAppearsForPreviewAndHidesAfterStopping() async throws {
    let model = CaptionModel(environment: [:], captionDismissDelay: .milliseconds(50))
    var shows = 0
    var hides = 0
    model.showOverlay = { shows += 1 }
    model.hideOverlay = { hides += 1 }
    #expect(!model.isOverlayVisible)
    model.preview()
    #expect(model.isOverlayVisible && shows == 1)
    #expect(!model.canCloseCaptionWindow)
    model.closeCaptionWindow()
    #expect(model.isOverlayVisible)
    model.stop()
    #expect(model.isOverlayVisible && model.canCloseCaptionWindow)
    model.isBusy = true
    try await Task.sleep(for: .milliseconds(150))
    #expect(!model.isOverlayVisible && hides == 1)
}

@MainActor
@Test func restartingCaptionsCancelsThePreviousDismissal() async throws {
    let model = CaptionModel(environment: [:], captionDismissDelay: .milliseconds(50))
    var hides = 0
    model.hideOverlay = { hides += 1 }
    model.beginCaptionDisplay()
    model.finishCaptionDisplay()
    model.isRunning = true
    model.beginCaptionDisplay()
    model.closeCaptionWindow()
    try await Task.sleep(for: .milliseconds(150))
    #expect(model.isOverlayVisible && hides == 0)
    model.isRunning = false
    model.finishCaptionDisplay()
    try await Task.sleep(for: .milliseconds(150))
    #expect(!model.isOverlayVisible && hides == 1)
}

@MainActor
@Test func closingStoppedCaptionsCancelsTheTimerAndAllowsNextStart() async throws {
    let model = CaptionModel(environment: [:], captionDismissDelay: .milliseconds(50))
    var hides = 0
    model.hideOverlay = { hides += 1 }
    model.beginCaptionDisplay()
    model.finishCaptionDisplay()
    model.closeCaptionWindow()
    #expect(!model.isOverlayVisible && hides == 1)
    model.isRunning = true
    model.beginCaptionDisplay()
    try await Task.sleep(for: .milliseconds(150))
    #expect(model.isOverlayVisible && hides == 1)
    model.isRunning = false
    model.closeCaptionWindow()
}
