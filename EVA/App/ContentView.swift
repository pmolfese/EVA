//
//  ContentView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  One instance of this view per "main" `WindowGroup` window. Each owns its
//  own `recording` — see REWIND.md "EVA as a multi-window app" — so two
//  windows genuinely show two different files rather than two views onto one
//  shared `@State` the way the single-`Window` design worked before.
//

import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// A set of dropped .mff URLs awaiting the combine sheet.
struct CombineRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// What a recording window exposes to the File menu's "Close File" — see
/// `CloseFileButton` in `EVAApp.swift`.
///
/// A small struct rather than a raw `Binding<MFFRecording?>`, so the command
/// can ask "is there anything to close" and trigger closing without also
/// being able to reach in and overwrite `recording` directly. `close()` is
/// `closeRecording()` itself, which also tears down the recording and clears
/// drop/importer state — a bare binding would make it too easy to bypass
/// that by just setting `recording = nil`.
struct RecordingWindowActions {
    var hasRecording: Bool
    var close: () -> Void
}

extension FocusedValues {
    var recordingWindowActions: RecordingWindowActions? {
        get { self[RecordingWindowActionsKey.self] }
        set { self[RecordingWindowActionsKey.self] = newValue }
    }

    private struct RecordingWindowActionsKey: FocusedValueKey {
        typealias Value = RecordingWindowActions
    }
}

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow

    @AppStorage(ToolbarButtonLabels.storageKey) private var showsToolbarButtonLabels = true

    @State private var recording: MFFRecording?
    /// Set only by the fork-claim branch in `.onAppear`, and read exactly
    /// once — by `WaveformMarkerContainer` the first time it builds a
    /// `WaveformView` for `recording.id`. Cleared by every other path that
    /// sets `recording` (`open(_:)`), so a fork claimed once cannot leak
    /// into a later, ordinary file opened into the same window.
    @State private var claimedForkSeed: PendingWindowForks.Payload?
    /// Every recording window needs *some* `BatchController` in its
    /// environment, because `WaveformView` unconditionally reads one (for
    /// `autoStartBatchIfNeeded()`, which lets a windowed batch run resume
    /// review inside whichever window shows the current job's file). This
    /// instance is never driven by anything — batch now runs in its own
    /// dedicated window (`BatchWindowView`), which owns the controller that
    /// actually matters. `isActive` stays permanently false here, so
    /// `autoStartBatchIfNeeded()`'s guard fails immediately and the rest of
    /// that method never runs. Cheap enough not to be worth a special-cased
    /// optional environment key just to avoid instantiating an idle object.
    @State private var batch = BatchController()

    @State private var showsFileImporter = false
    @State private var isDropTargeted = false
    @State private var openError: String?
    /// Multiple .mff files dropped at once → present the combine sheet.
    @State private var combineRequest: CombineRequest?
    /// Guards `PendingWindowOpens` so a window claims its handoff at most
    /// once — `.onAppear` can in principle fire more than once across a
    /// view's lifetime, and claiming is destructive (`removeFirst()`), so a
    /// second fire must not steal the *next* window's file.
    @State private var hasClaimedPendingOpen = false

    var body: some View {
        Group {
            if let recording {
                WaveformMarkerContainer(recording: recording, forkSeed: claimedForkSeed)
                    .id(recording.id)
            } else {
                launchScreen
            }
        }
        .environment(batch)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 4, dash: [10, 6]))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            // Deliberately always loads into *this* window, even when it
            // already has a recording open — unlike the menu's "Open
            // Recording…", which always opens a new one (see
            // `OpenRecordingButton`). A drop is inherently targeted: you put
            // it on this window, so this window is where it goes, same as
            // before multi-window existed.
            openDroppedURLs(urls)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        // Finder/Open With launches (and open-file Apple events delivered to an
        // already-running app) arrive here because Info.plist declares MFF as a
        // document type. Keep this on the same path as the Open panel and drag
        // and drop so validation, package handling, and security-scoped access
        // remain identical.
        //
        // Reuses *this* window if it is empty, otherwise opens a sibling —
        // deliberately not the menu command's unconditional "always new"
        // (`OpenRecordingButton`). On a cold launch this is what keeps a Finder
        // double-click from producing an extra empty window: `WindowGroup`
        // hands the open-file event to the launch window it is creating, whose
        // `recording` is still nil, so it fills itself and never becomes a
        // second window the way `Window` used to before 0.1.7.
        //
        // Verified 2026-08-15 NOT to cover every case, though: close a
        // recording (window goes back to empty) and *then* double-click a
        // file, and `WindowGroup` was observed spawning a fresh scene for the
        // event rather than routing it to that already-open empty window —
        // this check runs, but on the new instance, whose `recording` is
        // *also* nil, so it fills itself too. The net effect is a stray empty
        // window left sitting next to the new one, harmless but not what
        // "reuse if empty" was written to do. Fixing that means intercepting
        // the open request at the `NSApplicationDelegate` level
        // (`application(_:open:)`) instead of `.onOpenURL`, so EVA decides
        // which window receives it before `WindowGroup` does — see
        // ROADMAP.md's "App-level fixes" for the write-up. Left as-is for now:
        // the workaround (close the stray window) is cheap, and the fix
        // touches launch-routing internals this project has been burned by
        // guessing at before.
        .onOpenURL { url in
            if recording == nil {
                _ = openSelectedURLs([url])
            } else {
                PendingWindowOpens.shared.push([url])
                openWindow(id: "main")
            }
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.mff, .data, .plainText],
            allowsMultipleSelection: true
        ) { result in
            handleImportResult(result)
        }
        .sheet(item: $combineRequest) { request in
            CombineRecordingsSheet(
                urls: request.urls,
                onComplete: { packageURL in
                    combineRequest = nil
                    open(packageURL)
                },
                onCancel: { combineRequest = nil }
            )
        }
        .onAppear {
            guard !hasClaimedPendingOpen else { return }
            hasClaimedPendingOpen = true
            // Fork first: a window is created for exactly one reason (an
            // ordinary open, or a fork), so the two queues never both have an
            // entry meant for *this* window, but checking fork first keeps
            // that assumption from mattering.
            if let fork = PendingWindowForks.shared.claim() {
                claimedForkSeed = fork
                recording = MFFRecording(packageURL: fork.packageURL)
            } else if let urls = PendingWindowOpens.shared.claim() {
                _ = openSelectedURLs(urls)
            }
        }
        .focusedSceneValue(\.recordingWindowActions, RecordingWindowActions(
            hasRecording: recording != nil, close: closeRecording
        ))
        .background(WindowAccessor(
            hasRecording: recording != nil,
            onConfirmedClose: closeRecording,
            onBecomeMain: publishChannelSetContextForThisWindow
        ))
    }

    /// Closes the current recording and returns the window to a fresh launch
    /// state. Because `WaveformView` is keyed by `recording.id`, dropping the
    /// recording discards all of its per-recording in-memory state; opening a
    /// new file builds a brand-new view.
    /// `WindowAccessor`'s `onBecomeMain` callback — see
    /// `WaveformView.publishChannelSetContext()` for the full picture. This
    /// is the same write from `ContentView`'s own `recording`, so the
    /// Channel Sets editor updates the moment you click into a *different*
    /// already-loaded recording window, not only when a window first loads
    /// or edits a channel's role.
    private func publishChannelSetContextForThisWindow() {
        ChannelSetStore.shared.activeSensorLayout = recording?.sensorLayout
        ChannelSetStore.shared.activeChannelNames = recording?.signal?.channelNames
        if let recording {
            ChannelsWindowModel.shared.activateRecording(id: recording.id)
        }
    }

    private func closeRecording() {
        if let recording {
            ChannelsWindowModel.shared.removeRecording(id: recording.id)
        }
        recording?.tearDownForClose()
        recording = nil
        claimedForkSeed = nil
        openError = nil
        isDropTargeted = false
        showsFileImporter = false
    }

    private var launchScreen: some View {
        VStack(spacing: 0) {
            launchControlBar

            Divider()

            startScreen
        }
    }

    private var launchControlBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Amplitude")
                        .font(.caption.weight(.semibold))
                        .frame(width: 72, alignment: .leading)
                    Slider(value: .constant(100.0), in: 10...1000, step: 10)
                        .frame(width: 170)
                        .disabled(true)
                    Text("100 µV")
                        .font(.caption.monospacedDigit())
                        .frame(width: 64, alignment: .trailing)
                }
                HStack(spacing: 8) {
                    Text("Time Scale")
                        .font(.caption.weight(.semibold))
                        .frame(width: 72, alignment: .leading)
                    Slider(value: .constant(1.0), in: 0.2...8, step: 0.1)
                        .frame(width: 170)
                        .disabled(true)
                    Text("1.0x")
                        .font(.caption.monospacedDigit())
                        .frame(width: 64, alignment: .trailing)
                }
            }

            HStack(spacing: 6) {
                idleToolbarButton(name: "icon.mri", label: "MRI")
                idleToolbarButton(name: "icon.filter", label: "Filter")
                idleToolbarButton(name: "icon.artifacts", label: "Artifacts")
                idleToolbarButton(name: "icon.process", label: "Processing", buttonLabel: "PROCESS")
                idleToolbarButton(name: "icon.eeg-processing", label: "EEG Processing", buttonLabel: "EEG")
                idleToolbarButton(name: "icon.events", label: "Events")
            }

            Spacer(minLength: 12)

            idleStatusLog
                .frame(width: 240)

            Text("No recording open")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func idleToolbarButton(
        name: String,
        label: String,
        buttonLabel: String? = nil,
        inactiveForeground: Color = .primary
    ) -> some View {
        Button {} label: {
            ToolbarIcon(
                name: name,
                label: showsToolbarButtonLabels ? (buttonLabel ?? label) : nil,
                inactiveForeground: inactiveForeground
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .disabled(true)
        .help("Open an MFF recording to use \(label).")
    }

    private var idleStatusLog: some View {
        Text("Ready")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )
            .accessibilityLabel("Status log")
    }

    private var startScreen: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("EVA")
                    .font(.largeTitle.weight(.semibold))
                Text("Electrophysiology Viewer and Analysis")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            // Loads into *this* window directly, unlike the menu command —
            // this button is only ever visible when the window is already
            // empty, so there is nothing here to preserve by opening a
            // sibling instead.
            Button("Open Recording...") {
                showsFileImporter = true
            }
            .keyboardShortcut("o", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("Drop .mff, BrainVision, EDF, Persyst, or BESA .avr/.mul recordings here")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("Drop two or more .mff recordings together to combine or average them")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let openError {
                Text(openError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            openSelectedURLs(urls)
        case .failure(let error):
            openError = error.localizedDescription
        }
    }

    private func openDroppedURLs(_ urls: [URL]) -> Bool {
        openSelectedURLs(urls)
    }

    @discardableResult
    private func openSelectedURLs(_ urls: [URL]) -> Bool {
        let supportedURLs = urls.filter(isSupportedRecordingURL)
        let mffURLs = supportedURLs.filter { $0.pathExtension.lowercased() == "mff" }
        if mffURLs.count > 1 {
            combineRequest = CombineRequest(urls: mffURLs)
            return true
        }

        let brainVisionURLs = supportedURLs.filter(isBrainVisionURL)
        if !brainVisionURLs.isEmpty {
            return openBrainVisionSelection(brainVisionURLs)
        }

        guard let url = supportedURLs.first else {
            openError = "EVA can open .mff, BrainVision, EDF, Persyst, and BESA .avr/.mul recordings."
            return false
        }
        return open(url, securityScopedURLs: supportedURLs)
    }

    @discardableResult
    private func open(_ url: URL, securityScopedURLs: [URL] = []) -> Bool {
        guard isSupportedRecordingURL(url) else {
            openError = "EVA can open .mff, BrainVision, EDF, Persyst, and BESA .avr/.mul recordings."
            return false
        }

        openError = nil
        // Defensive, not just for the common case: an ordinary open must
        // never carry a stale fork claim into the new recording, however it
        // was reached.
        claimedForkSeed = nil
        recording = MFFRecording(packageURL: url, securityScopedURLs: securityScopedURLs)
        return true
    }

    private func isSupportedRecordingURL(_ url: URL) -> Bool {
        SignalImportReader.isSupportedRecordingURL(url)
    }

    private func isBrainVisionURL(_ url: URL) -> Bool {
        ["vhdr", "vmrk", "eeg"].contains(url.pathExtension.lowercased())
    }

    private func openBrainVisionSelection(_ urls: [URL]) -> Bool {
        guard let headerURL = brainVisionHeaderURL(from: urls) else {
            openError = "BrainVision recordings need a .vhdr header file."
            return false
        }

        var scopedURLs = urls
        if !selectionIncludesBrainVisionSet(urls) {
            guard let folderURL = requestBrainVisionFolderAccess(containing: headerURL) else {
                openError = "BrainVision recordings use .vhdr, .vmrk, and .eeg sidecar files. Select the containing folder or choose all three files together."
                return false
            }
            scopedURLs.append(folderURL)
        }

        return open(headerURL, securityScopedURLs: scopedURLs)
    }

    private func brainVisionHeaderURL(from urls: [URL]) -> URL? {
        if let header = urls.first(where: { $0.pathExtension.lowercased() == "vhdr" }) {
            return header
        }
        guard let sidecar = urls.first(where: isBrainVisionURL) else { return nil }
        return sidecar.deletingPathExtension().appendingPathExtension("vhdr")
    }

    private func selectionIncludesBrainVisionSet(_ urls: [URL]) -> Bool {
        let extensions = Set(urls.map { $0.pathExtension.lowercased() })
        return extensions.isSuperset(of: ["vhdr", "vmrk", "eeg"])
    }

    private func requestBrainVisionFolderAccess(containing headerURL: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = headerURL.deletingLastPathComponent()
        panel.prompt = "Grant Access"
        panel.message = "BrainVision recordings use multiple files. Select the folder that contains the .vhdr, .vmrk, and .eeg files."
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Intercepts the close button to show a discard-confirmation sheet when a
/// recording is open.
///
/// **Does not set a frame-autosave name.** It used to — keyed by a
/// `@State private var windowInstanceID = UUID()` generated fresh in
/// `ContentView` on every launch. That name can never match a previously
/// saved one, since it is different every time the app runs, so
/// `NSWindow.setFrameAutosaveName` was silently doing nothing useful: found
/// 2026-08-15 in manual testing, where two independently-positioned windows
/// both snapped back to "whichever moved most recently" on relaunch instead
/// of remembering their own spots. Worse, an imperative
/// `setFrameAutosaveName` call actively takes over frame persistence under
/// that key, which likely *suppressed* whatever automatic per-window-instance
/// restoration `WindowGroup` already provides for free — removing the call
/// is expected to let the platform default take over rather than trading one
/// broken scheme for another. Unverified without a relaunch test of its own.
struct WindowAccessor: NSViewRepresentable {
    var hasRecording: Bool = false
    var onConfirmedClose: (() -> Void)? = nil
    /// Called whenever this window becomes the app's main window — see
    /// `WaveformView.publishChannelSetContext()` for why: it's what makes the
    /// Channel Sets editor follow *focus* across multiple recording windows
    /// rather than only the one that loaded most recently.
    var onBecomeMain: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hasRecording = hasRecording
        context.coordinator.onConfirmedClose = onConfirmedClose
        context.coordinator.onBecomeMain = onBecomeMain
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            context.coordinator.attach(to: window)
        }
    }

    /// Intercepts `windowShouldClose` to show a discard-confirmation alert sheet
    /// when a recording is open; forwards all other delegate messages to SwiftUI's
    /// original delegate so lifecycle and state restoration keep working.
    ///
    /// Also observes `didBecomeMainNotification` on the window, for
    /// `onBecomeMain`. Plain `NotificationCenter`, not `@FocusedValue` — a
    /// `.commands`-hosted mirror was tried first for the Channel Sets case
    /// this exists to serve and found unreliable (see
    /// `ChannelSetStore.swift`'s file header); a direct AppKit notification
    /// on the window itself has no equivalent "does this actually
    /// re-evaluate" uncertainty.
    final class Coordinator: NSObject, NSWindowDelegate {
        var hasRecording = false
        var onConfirmedClose: (() -> Void)?
        var onBecomeMain: (() -> Void)?
        private weak var originalDelegate: NSWindowDelegate?
        private var becomeMainObserver: NSObjectProtocol?

        deinit {
            if let becomeMainObserver {
                NotificationCenter.default.removeObserver(becomeMainObserver)
            }
        }

        func attach(to window: NSWindow) {
            if becomeMainObserver == nil {
                becomeMainObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeMainNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.onBecomeMain?()
                }
                // The window may already be main by the time this attaches
                // (e.g. a freshly-opened window becomes main before SwiftUI
                // hands this coordinator the window at all), in which case
                // the notification above will never fire for it — fire once
                // manually so that case is not silently missed.
                if window.isMainWindow { onBecomeMain?() }
            }
            guard window.delegate !== self else { return }
            originalDelegate = window.delegate
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if hasRecording {
                showDiscardSheet(for: sender)
                return false
            }
            if let originalDelegate,
               originalDelegate.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))) {
                return originalDelegate.windowShouldClose?(sender) ?? true
            }
            return true
        }

        private func showDiscardSheet(for window: NSWindow) {
            let alert = NSAlert()
            alert.messageText = "Discard unsaved work?"
            alert.informativeText = "Closing this recording will discard any processing that has not been exported. This cannot be undone."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn {
                    self?.onConfirmedClose?()
                }
            }
        }

        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (originalDelegate?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if originalDelegate?.responds(to: aSelector) == true { return originalDelegate }
            return super.forwardingTarget(for: aSelector)
        }
    }
}

#Preview {
    ContentView()
}

/// Hosts the `UserMarker` SwiftData query so a marker-table change re-evaluates
/// only this tiny view — not the whole `WaveformView` body (ROADMAP A3). Projects
/// this recording's markers to Equatable value signatures and passes them in, so
/// `WaveformView` re-renders only when its own markers actually change.
private struct WaveformMarkerContainer: View {
    let recording: MFFRecording
    var forkSeed: PendingWindowForks.Payload? = nil
    @Query private var markers: [UserMarker]

    var body: some View {
        WaveformView(
            recording: recording,
            userMarkers: markers
                .filter { $0.packageName == recording.packageName }
                .map {
                    WaveformUserMarkerSignature(
                        idHash: $0.persistentModelID.hashValue,
                        timeSeconds: $0.timeSeconds,
                        note: $0.note
                    )
                },
            forkSeed: forkSeed
        )
    }
}
