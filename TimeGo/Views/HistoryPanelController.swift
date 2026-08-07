import AppKit
import SwiftUI

/// Panel controller for the statistics / history view.
@MainActor
final class HistoryPanelController: NSObject, NSWindowDelegate {
    static let shared = HistoryPanelController()

    private var panel: NSPanel?
    private var store: SessionStore?
    private var historyStore: HistoryStore?

    func configure(store: SessionStore, historyStore: HistoryStore) {
        self.store = store
        self.historyStore = historyStore
    }

    func show() {
        guard let store, let historyStore else { return }

        L10n.shared.apply(store.settings.language)
        historyStore.reload()

        if panel == nil {
            panel = makePanel(store: store, historyStore: historyStore)
        }
        updateTitle()

        NSApp.setActivationPolicy(.regular)
        centerOnActiveScreen()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async { [weak self] in
            self?.centerOnActiveScreen()
            self?.panel?.makeKeyAndOrderFront(nil)
        }
    }

    func updateTitle() {
        panel?.title = L10n.shared.t("history.title")
    }

    func close() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func centerOnActiveScreen() {
        guard let panel else { return }

        let mouseScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        let screen = mouseScreen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else {
            panel.center()
            return
        }

        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.midY - frame.height / 2
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        panel.setFrame(frame, display: true)
    }

    private func makePanel(store: SessionStore, historyStore: HistoryStore) -> NSPanel {
        let root = HistoryView(onClose: { [weak self] in
            self?.close()
        })
        .environmentObject(store)
        .environmentObject(historyStore)
        .environmentObject(L10n.shared)

        let hosting = NSHostingController(rootView: root)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.shared.t("history.title")
        panel.contentViewController = hosting
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.minSize = NSSize(width: 420, height: 360)
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = NSColor(calibratedRed: 0.95, green: 0.96, blue: 0.94, alpha: 1)
        return panel
    }
}