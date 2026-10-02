import AppKit
import Speech
import SwiftUI

@main
struct BilingualLiveCaptionApp {
    @MainActor
    static func main() {
        if let position = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > position + 1 {
            do {
                try PreviewRenderer.render(to: CommandLine.arguments[position + 1])
                print("Rendered offline UI previews.")
                exit(0)
            } catch {
                print(error.localizedDescription)
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--check-local-model") {
            Task {
                do {
                    print("Apple transcription available: \(SpeechTranscriber.isAvailable)")
                    print("Supported locales: \(await SpeechTranscriber.supportedLocales.map(\.identifier).sorted())")
                    print("Installed locales: \(await SpeechTranscriber.installedLocales.map(\.identifier).sorted())")
                    let module = try await AppleTranscriber.module(language: "en-US")
                    print("Configured module status: \(await AssetInventory.status(forModules: [module]))")
                    let installed = try await AppleTranscriber.isInstalled(language: "en-US")
                    print("Apple English model installed: \(installed)")
                    exit(0)
                } catch {
                    print("Apple model check: \(error.localizedDescription)")
                    exit(1)
                }
            }
            RunLoop.main.run()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
class CaptionPanel: NSPanel {
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
    override func performClose(_ sender: Any?) { onDismiss?() }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let contentView {
            let point = contentView.convert(event.locationInWindow, from: nil)
            if contentView.bounds.insetBy(dx: 6, dy: 6).contains(point) {
                makeKey()
                performDrag(with: event)
                return
            }
        }
        super.sendEvent(event)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = CaptionModel(preferences: UserPreferences(defaults: .standard), credentials: KeychainCredentials())
    private var window: NSWindow!
    private var overlay: CaptionPanel!
    private var statusItem: NSStatusItem!
    private var captionMenuItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Show Controls", action: #selector(showControls), keyEquivalent: ",")
        let captionItem = appMenu.addItem(withTitle: "Show Captions", action: #selector(toggleCaptions), keyEquivalent: "l")
        captionItem.target = self
        captionMenuItems.append(captionItem)
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Bilingual Live Caption", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let item = NSMenuItem()
        item.submenu = appMenu
        menu.addItem(item)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 740),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Bilingual Live Caption"
        window.contentView = NSHostingView(rootView: ControlsView(model: model))
        window.minSize = NSSize(width: 570, height: 640)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameUsingName("CaptionControls")
        window.setFrameAutosaveName("CaptionControls")

        overlay = CaptionPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 140),
                          styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay.title = "Live Captions"
        overlay.isReleasedWhenClosed = false
        overlay.onDismiss = { [weak self] in self?.hideCaptions() }
        overlay.isFloatingPanel = true
        overlay.hidesOnDeactivate = false
        overlay.isMovableByWindowBackground = true
        overlay.level = .floating
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.minSize = NSSize(width: 280, height: 80)
        overlay.contentView = NSHostingView(rootView: OverlayView(model: model))
        if let screen = NSScreen.main {
            overlay.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 360, y: screen.visibleFrame.minY + 55))
        }
        overlay.setFrameUsingName("CaptionOverlay")
        overlay.setFrameAutosaveName("CaptionOverlay")
        model.showOverlay = { [weak self] in self?.showCaptions() }
        model.hideOverlay = { [weak self] in self?.hideCaptions() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: "Bilingual Live Caption")
        let statusMenu = NSMenu()
        statusMenu.addItem(withTitle: "Show Controls", action: #selector(showControls), keyEquivalent: "")
        captionMenuItems.append(statusMenu.addItem(withTitle: "Show Captions", action: #selector(toggleCaptions), keyEquivalent: ""))
        statusMenu.addItem(withTitle: "Stop Captions", action: #selector(stopCaptions), keyEquivalent: "")
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in statusMenu.items { item.target = self }
        statusMenu.items.last?.target = NSApp
        statusItem.menu = statusMenu
        showControls()
        if model.isOverlayVisible { showCaptions() }
        if CommandLine.arguments.contains("--preview") { model.preview() }
    }

    @objc private func showControls() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showCaptions() {
        overlay.orderFrontRegardless()
        setCaptionVisibility(true)
    }
    @objc private func hideCaptions() {
        overlay.orderOut(nil)
        setCaptionVisibility(false)
    }
    @objc private func toggleCaptions() {
        if model.isOverlayVisible { hideCaptions() }
        else { showCaptions() }
    }
    private func setCaptionVisibility(_ visible: Bool) {
        model.isOverlayVisible = visible
        for item in captionMenuItems { item.title = visible ? "Hide Captions" : "Show Captions" }
    }
    @objc private func stopCaptions() { model.stop() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        window.saveFrame(usingName: "CaptionControls")
        overlay.saveFrame(usingName: "CaptionOverlay")
        Task {
            await model.quit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControls()
        return true
    }
}
