import AppKit
import Combine
import SwiftUI
import VoxKit

/// What the correction panel is showing; the state machine lives in
/// `PreviewSession` (VoxKit), this only mirrors it for the view.
@MainActor
final class CorrectionPanelModel: ObservableObject {
    enum Content: Equatable {
        case editor
        case empty(String)
    }

    @Published var text = ""
    @Published var content: Content = .editor
    @Published var title = ""
    @Published var subtitle = ""
    @Published var isEditing = false
    @Published var idleTimeoutSeconds: Double?

    var onTextChange: ((String) -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
}

/// A floating box under the menu bar holding a transcript the user may edit.
///
/// Both correction surfaces use it: the pre-paste preview (idle timer, then
/// commits on its own) and the fix-last editor (waits for Return or Esc). It
/// is a non-activating panel that takes key focus without activating Vox, so
/// the app the user was typing in stays frontmost and auto-paste still lands
/// there once the panel goes away.
@MainActor
final class CorrectionPanelController {
    struct Request {
        var title: String
        var subtitle: String
        var text: String
        /// `nil` never auto-commits.
        var idleTimeoutSeconds: Double?
        var onCommit: (PreviewSession.Commit) -> Void
        var onDismiss: () -> Void
    }

    private let model = CorrectionPanelModel()
    private var panel: NSPanel?
    private var session: PreviewSession?
    private var request: Request?
    private var idleTimer: DispatchWorkItem?
    private var emptyStateTimer: DispatchWorkItem?

    private static let size = NSSize(width: 460, height: 132)
    private static let topMargin: CGFloat = 12

    var isPresenting: Bool { session != nil }

    init() {
        model.onTextChange = { [weak self] text in self?.perform(self?.session?.textDidChange(text) ?? []) }
        model.onConfirm = { [weak self] in self?.perform(self?.session?.confirm() ?? []) }
        model.onCancel = { [weak self] in
            guard let self else { return }
            if session == nil {
                hidePanel()
            } else {
                perform(session?.cancel() ?? [])
            }
        }
    }

    func present(_ request: Request) {
        // A dictation finishing while an earlier box is still up: the earlier
        // one is dropped, not silently pasted.
        if session != nil { perform(session?.cancel() ?? []) }
        emptyStateTimer?.cancel()

        self.request = request
        var session = PreviewSession(text: request.text, idleTimeoutSeconds: request.idleTimeoutSeconds)
        let actions = session.start()
        self.session = session

        model.title = request.title
        model.subtitle = request.subtitle
        model.text = request.text
        model.content = .editor
        model.isEditing = false
        model.idleTimeoutSeconds = request.idleTimeoutSeconds
        showPanel(focusText: true)
        perform(actions)
    }

    /// The fix-last hotkey with nothing to fix: say so briefly, then go away.
    func presentEmptyState(title: String, message: String, duration: Double = 2.0) {
        guard session == nil else { return }
        emptyStateTimer?.cancel()
        model.title = title
        model.subtitle = ""
        model.content = .empty(message)
        model.idleTimeoutSeconds = nil
        showPanel(focusText: false)
        let timer = DispatchWorkItem {
            Task { @MainActor [weak self] in self?.hidePanel() }
        }
        emptyStateTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: timer)
    }

    private func perform(_ actions: [PreviewSession.Action]) {
        for action in actions {
            switch action {
            case .armIdleTimer(let seconds):
                idleTimer?.cancel()
                let timer = DispatchWorkItem {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        perform(session?.idleTimerFired() ?? [])
                    }
                }
                idleTimer = timer
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timer)
            case .cancelIdleTimer:
                idleTimer?.cancel()
                idleTimer = nil
                model.isEditing = true
            case .commit(let commit):
                let request = finishSession()
                request?.onCommit(commit)
            case .dismiss:
                let request = finishSession()
                request?.onDismiss()
            }
        }
    }

    /// Tears the box down *before* the caller acts on the result, so an
    /// auto-paste finds the previous app's window key again.
    private func finishSession() -> Request? {
        idleTimer?.cancel()
        idleTimer = nil
        let request = self.request
        self.request = nil
        session = nil
        hidePanel()
        return request
    }

    private func showPanel(focusText: Bool) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.alphaValue = 0
        if focusText {
            panel.makeKeyAndOrderFront(nil)
            if let textView = findTextView(in: panel.contentView) {
                panel.makeFirstResponder(textView)
            }
        } else {
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func hidePanel() {
        emptyStateTimer?.cancel()
        emptyStateTimer = nil
        guard let panel else { return }
        panel.orderOut(nil)
        panel.alphaValue = 0
    }

    private func makePanel() -> NSPanel {
        let panel = CorrectionPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentViewController = NSHostingController(rootView: CorrectionPanelView(model: model))
        panel.contentView?.wantsLayer = true
        return panel
    }

    private func findTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }

    /// Same spot as the recording waveform: under the menu bar on the screen
    /// the pointer is on.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - Self.size.width / 2,
            y: visible.maxY - Self.size.height - Self.topMargin
        )
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: false)
    }
}

/// A borderless panel refuses key status by default; this one needs it so
/// the text view receives keystrokes without the user clicking into it.
private final class CorrectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct CorrectionPanelView: View {
    @ObservedObject var model: CorrectionPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "pencil.line")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(model.title)
                    .font(.system(size: 12, weight: .semibold))
                if !model.subtitle.isEmpty {
                    Text(model.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            switch model.content {
            case .editor:
                CorrectionTextView(
                    text: $model.text,
                    onConfirm: { model.onConfirm?() },
                    onCancel: { model.onCancel?() },
                    onChange: { model.onTextChange?($0) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty(let message):
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(2)
    }

    private var hint: String {
        switch model.content {
        case .empty:
            return ""
        case .editor:
            if model.isEditing || model.idleTimeoutSeconds == nil {
                return "↩ confirm · ⇧↩ newline · Esc cancel"
            }
            return "Pasting shortly · type to edit · ↩ now · Esc cancel"
        }
    }
}

/// `TextEditor` cannot tell Return from a newline; this can. Return confirms,
/// Shift-Return inserts a line break, Esc cancels.
struct CorrectionTextView: NSViewRepresentable {
    @Binding var text: String
    var onConfirm: () -> Void
    var onCancel: () -> Void
    var onChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let textView = KeyRoutingTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.onConfirm = onConfirm
        textView.onCancel = onCancel
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? KeyRoutingTextView else { return }
        textView.onConfirm = onConfirm
        textView.onCancel = onCancel
        context.coordinator.parent = self
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CorrectionTextView

        init(_ parent: CorrectionTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.onChange(textView.string)
        }
    }
}

private final class KeyRoutingTextView: NSTextView {
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // kVK_Return / kVK_ANSI_KeypadEnter / kVK_Escape
        switch event.keyCode {
        case 36, 76:
            if event.modifierFlags.contains(.shift) {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                onConfirm?()
            }
        case 53:
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
