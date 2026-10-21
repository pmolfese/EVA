// Floating, per-recording Decision Matrix. The hosting view stays mounted when
// hidden so sorting, zoom and selection survive a Show/Hide round trip.
import AppKit
import SwiftUI

struct PSADecisionMatrixPanel<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    var title: String
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AnchorView {
        let anchor = AnchorView()
        anchor.didAttach = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return anchor
    }

    func updateNSView(_ anchor: AnchorView, context: Context) {
        context.coordinator.update(
            title: title, isPresented: isPresented,
            presentation: $isPresented, content: content()
        )
        context.coordinator.attach(to: anchor.window)
    }

    static func dismantleNSView(_ anchor: AnchorView, coordinator: Coordinator) {
        anchor.didAttach = nil
        coordinator.tearDown()
    }

    final class AnchorView: NSView {
        var didAttach: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Presentation changes must follow the SwiftUI mounting transaction.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                didAttach?(window)
            }
        }
    }

    /// Switching between the waveform and the palette should act on the first
    /// click, rather than consuming that click just to activate the window.
    final class HostingView: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private var panel: NSPanel?
        private var host: HostingView?
        private weak var parent: NSWindow?
        private var presentation: Binding<Bool>?
        private var wantsPresentation = false
        private var positioned = false
        // One last-used layout for newly opened matrices across launches.
        // Save explicitly: several recording panels may coexist, whereas an
        // AppKit frame-autosave name can be owned by only one window at a time.
        private let savedFrameName = "EVADecisionMatrixPanel"

        func update(title: String, isPresented: Bool, presentation: Binding<Bool>, content: Content) {
            self.presentation = presentation
            wantsPresentation = isPresented
            if let host {
                host.rootView = content
            } else {
                let host = HostingView(rootView: content)
                host.sizingOptions = []
                host.autoresizingMask = [.width, .height]
                let panel = NSPanel(
                    contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                    styleMask: [.titled, .closable, .resizable, .utilityWindow],
                    backing: .buffered, defer: false
                )
                panel.contentView = host
                panel.setContentSize(NSSize(width: 900, height: 560))
                panel.isReleasedWhenClosed = false
                panel.isFloatingPanel = true
                panel.hidesOnDeactivate = true
                panel.collectionBehavior = [.fullScreenAuxiliary]
                panel.minSize = NSSize(width: 780, height: 480)
                panel.delegate = self
                self.host = host
                self.panel = panel
            }
            panel?.title = "Decision Matrix — \(title)"
            synchronizeVisibility()
        }

        func attach(to window: NSWindow?) {
            guard parent !== window else { synchronizeVisibility(); return }
            if let panel { parent?.removeChildWindow(panel) }
            NotificationCenter.default.removeObserver(self)
            parent = window
            if let window {
                for name in [NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
                             NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(parentFocusChanged), name: name, object: window)
                }
            }
            synchronizeVisibility()
        }

        @objc private func parentFocusChanged(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in self?.synchronizeVisibility() }
        }

        private func synchronizeVisibility() {
            guard let panel else { return }
            guard wantsPresentation, let parent,
                  !parent.isMiniaturized,
                  parent.isMainWindow || panel.isKeyWindow else {
                savePlacement()
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
                return
            }
            if !positioned {
                if panel.setFrameUsingName(savedFrameName, force: true) {
                    // A remembered monitor may have been unplugged. Restore on
                    // the screen containing most of the frame, or the parent.
                    let screen = NSScreen.screens.max {
                        visibleArea(of: panel.frame, on: $0) < visibleArea(of: panel.frame, on: $1)
                    }
                    let target = screen.flatMap { visibleArea(of: panel.frame, on: $0) > 0 ? $0 : nil }
                        ?? parent.screen ?? NSScreen.main
                    if let target {
                        let visible = target.visibleFrame
                        var frame = panel.frame
                        frame.size.width = min(frame.width, visible.width)
                        frame.size.height = min(frame.height, visible.height)
                        frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
                        frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
                        panel.setFrame(frame, display: false)
                    }
                } else {
                    let screen = parent.screen?.visibleFrame ?? parent.frame
                    panel.setFrameOrigin(NSPoint(
                        x: max(screen.minX, min(parent.frame.maxX - panel.frame.width - 24, screen.maxX - panel.frame.width)),
                        y: max(screen.minY, min(parent.frame.maxY - panel.frame.height - 72, screen.maxY - panel.frame.height))
                    ))
                }
                positioned = true
            }
            if panel.parent !== parent { parent.addChildWindow(panel, ordered: .above) }
            if !panel.isVisible { panel.orderFront(nil) }
        }

        private func visibleArea(of frame: NSRect, on screen: NSScreen) -> CGFloat {
            let intersection = frame.intersection(screen.visibleFrame)
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }

        private func savePlacement() {
            guard positioned, let panel, panel.isVisible else { return }
            panel.saveFrame(usingName: savedFrameName)
        }

        func windowDidMove(_ notification: Notification) { savePlacement() }
        func windowDidResize(_ notification: Notification) { savePlacement() }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            savePlacement()
            wantsPresentation = false
            sender.parent?.removeChildWindow(sender)
            sender.orderOut(nil)
            presentation?.wrappedValue = false
            return false
        }

        func tearDown() {
            savePlacement()
            wantsPresentation = false
            NotificationCenter.default.removeObserver(self)
            if let panel { panel.parent?.removeChildWindow(panel) }
            panel?.delegate = nil
            panel?.orderOut(nil)
            panel?.contentView = nil
            host = nil
            panel = nil
            presentation = nil
            parent = nil
        }
    }
}
