import AppKit
import ApplicationServices
import Combine
import SwiftUI
import VoxKit

/// What the HUD view observes. Only `phase` and `edge` are published; level
/// readings go straight into `meter`, which the waveform's own timeline reads
/// every frame — publishing ~12 readings a second would re-render the whole
/// view tree for each one.
@MainActor
final class HUDModel: ObservableObject {
    @Published fileprivate(set) var phase: HUDPhase = .hidden
    @Published fileprivate(set) var edge: HUDPlacement.Edge = .top
    let meter = MeterBox()
}

/// Reference-type home for the `LevelSmoother` value, so the render loop can
/// advance it in place without going through SwiftUI state.
@MainActor
final class MeterBox {
    var meter = LevelSmoother()
}

/// A borderless panel near the top of the screen the user is working on:
/// visible over full-screen apps and on every Space, never takes focus, and
/// never eats a click. Phase changes come in as `HUDEvent`s and run through
/// `HUDStateMachine`; this class only handles windowing.
@MainActor
final class RecordingOverlayController {
    private let model = HUDModel()
    private var machine = HUDStateMachine()
    /// Read by `HUDDemo`'s snapshot mode; never mutated outside this class.
    private(set) var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    /// Guards the fade-out completion against a show that happened during
    /// the fade; see `PanelVisibility`.
    private var visibility = PanelVisibility()
    private var observers: [NSObjectProtocol] = []

    /// Panel size: the widest capsule plus room for its shadow. The panel
    /// stays this size; the capsule inside sizes and animates itself.
    private static let panelSize = NSSize(width: 460, height: 84)

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reassertOnScreen(reposition: false) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reassertOnScreen(reposition: true) }
        })
    }

    // MARK: - Events

    func begin() {
        send(.began)
    }

    func send(_ event: HUDEvent) {
        let previous = machine.phase
        let effect = machine.send(event)
        let phase = machine.phase
        guard phase != previous || effect != .none else { return }

        if case .recording = phase { model.meter.meter.reset() }
        // Keep the last visible phase on screen while the panel fades out,
        // rather than flashing the placeholder content `.hidden` maps to.
        if phase != .hidden { model.phase = phase }

        dismissTask?.cancel()
        dismissTask = nil
        switch effect {
        case .present: showPanel()
        case .hide: hidePanel()
        case .none: break
        }
        if let delay = HUDStateMachine.autoDismissDelay(for: phase) {
            scheduleDismiss(after: delay, generation: machine.generation)
        }
    }

    func update(levelDB: Double) {
        model.meter.meter.ingest(db: levelDB)
    }

    private func scheduleDismiss(after delay: TimeInterval, generation: Int) {
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.send(.dismissed(generation: generation))
        }
    }

    // MARK: - Window

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        visibility.show()
        position(panel)
        // A fade-out may still be running: start from wherever it got to
        // rather than snapping, and make sure it is in front of *this* Space.
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.reduceMotion ? 0.1 : 0.16
            panel.animator().alphaValue = 1
        }
    }

    private func hidePanel() {
        guard let panel, let token = visibility.hide() else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibility.shouldOrderOut(afterHide: token) else { return }
                panel.orderOut(nil)
            }
        }
    }

    /// Moving to another Space (or a display being added, removed or
    /// rearranged) while the HUD is up: make sure it is still in front, and
    /// still on a screen that exists.
    private func reassertOnScreen(reposition: Bool) {
        guard visibility.isShown, let panel else { return }
        if reposition { position(panel) }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Above ordinary floating windows, and — with .fullScreenAuxiliary —
        // allowed onto a full-screen app's Space.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The capsule draws its own shadow: a window shadow is computed from
        // the content's alpha once and lags behind the capsule resizing.
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.alphaValue = 0
        let hosting = NSHostingView(rootView: HUDView(model: model))
        hosting.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = hosting
        return panel
    }

    /// The screen under the pointer, which is where the user is working —
    /// not necessarily the one with the key window or the menu bar.
    private func position(_ panel: NSPanel) {
        let screens = NSScreen.screens
        let mouse = NSEvent.mouseLocation
        guard let index = HUDPlacement.screenIndex(containing: mouse, frames: screens.map(\.frame)) else { return }
        let screen = screens[index]
        var obstacles = [CGRect(x: mouse.x - 12, y: mouse.y - 12, width: 24, height: 24)]
        if let caret = Self.focusedCaretRect() { obstacles.append(caret) }
        let placement = HUDPlacement.frame(
            size: Self.panelSize,
            in: screen.visibleFrame,
            avoiding: obstacles,
            margin: 0
        )
        model.edge = placement.edge
        panel.setFrame(placement.frame, display: false)
    }

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Where the text caret is in the focused app, if Accessibility access is
    /// already granted (auto-paste needs it) — Vox never prompts for it here.
    /// Best effort: many apps don't expose caret bounds, and a short messaging
    /// timeout keeps a hung app from stalling the hotkey.
    private static func focusedCaretRect() -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.05)
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
            let range
        else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &boundsValue
        ) == .success,
            let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect), rect.width >= 0, rect.height > 0 else {
            return nil
        }
        // AX uses top-left-origin global coordinates; Cocoa's origin is the
        // primary display's bottom-left.
        guard let primaryHeight = NSScreen.screens.first?.frame.maxY else { return nil }
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: max(rect.width, 2), height: rect.height)
    }
}

// MARK: - Views

struct HUDView: View {
    @ObservedObject var model: HUDModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            if model.edge == .bottom { Spacer(minLength: 0) }
            HUDCapsule(phase: model.phase, meter: model.meter)
                .padding(.vertical, 18)
            if model.edge == .top { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.82), value: PhaseKey(model.phase))
    }
}

/// Animation key: which phase is showing, ignoring the payload that only
/// changes text (elapsed-time origins, detail strings).
private enum PhaseKey: Hashable {
    case hidden, starting, recording, transcribing, refining, succeeded, failed

    init(_ phase: HUDPhase) {
        switch phase {
        case .hidden: self = .hidden
        case .starting: self = .starting
        case .recording: self = .recording
        case .transcribing: self = .transcribing
        case .refining: self = .refining
        case .succeeded: self = .succeeded
        case .failed: self = .failed
        }
    }
}

struct HUDCapsule: View {
    let phase: HUDPhase
    let meter: MeterBox
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .id(PhaseKey(phase))
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .frame(height: 44)
            .frame(minWidth: 200, maxWidth: 420)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                Capsule(style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.18), radius: 10, y: 3)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.08), lineWidth: 0.5)
            )
            .clipShape(Capsule(style: .continuous))
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .hidden, .starting:
            HStack(spacing: 10) {
                PhaseIcon(symbol: "mic.fill", tint: .secondary, palette: false)
                Text("Starting…").hudTitle().foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(width: 236)
        case .recording(let since):
            HStack(spacing: 10) {
                RecordingDot()
                Waveform(meter: meter)
                    .frame(width: 170, height: 24)
                ElapsedText(since: since, style: .clock)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Recording")
        case .transcribing:
            HStack(spacing: 10) {
                Spinner()
                Text("Transcribing…").hudTitle()
                Spacer(minLength: 0)
            }
            .frame(width: 236)
        case .refining(let mode, let model, let since):
            HStack(spacing: 10) {
                Spinner()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Waiting for LLM…").hudTitle()
                    Text([mode, model].compactMap { $0 }.joined(separator: " · ")).hudDetail()
                }
                .frame(maxWidth: 260, alignment: .leading)
                Spacer(minLength: 12)
                ElapsedText(since: since, style: .seconds)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 236)
        case .succeeded(let outcome):
            HStack(spacing: 10) {
                if outcome.style == .success {
                    PhaseIcon(symbol: "checkmark.circle.fill", tint: .green)
                } else {
                    PhaseIcon(symbol: "waveform", tint: .secondary, palette: false)
                }
                TitleAndDetail(title: outcome.title, detail: outcome.detail)
                Spacer(minLength: 0)
            }
            .frame(minWidth: 176)
        case .failed(let failure):
            HStack(spacing: 10) {
                PhaseIcon(
                    symbol: failure.fallbackNote == nil ? "xmark.octagon.fill" : "exclamationmark.triangle.fill",
                    tint: failure.fallbackNote == nil ? .red : .orange
                )
                TitleAndDetail(
                    title: failure.title,
                    detail: failure.fallbackNote ?? failure.detail
                )
                Spacer(minLength: 0)
            }
            .frame(minWidth: 236)
        }
    }
}

private struct TitleAndDetail: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).hudTitle()
            if let detail, !detail.isEmpty {
                Text(detail).hudDetail()
            }
        }
        .frame(maxWidth: 330, alignment: .leading)
    }
}

private extension Text {
    func hudTitle() -> some View {
        font(.system(size: 13, weight: .semibold)).lineLimit(1)
    }

    func hudDetail() -> some View {
        font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
    }
}

/// Filled status symbols drawn as a white glyph on a solid colour disc or
/// triangle — full contrast on both light and dark material, where the
/// hierarchical style washes the background layer out.
private struct PhaseIcon: View {
    let symbol: String
    let tint: Color
    var palette = true

    var body: some View {
        Group {
            if palette {
                Image(systemName: symbol)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, tint)
            } else {
                Image(systemName: symbol).foregroundStyle(tint)
            }
        }
        .font(.system(size: 18, weight: .semibold))
        .frame(width: 22, height: 22)
    }
}

private struct Spinner: View {
    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.small)
            .frame(width: 22, height: 22)
    }
}

/// A red dot that breathes gently while recording; steady under Reduce Motion.
private struct RecordingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 9, height: 9)
            .opacity(dim ? 0.45 : 1)
            .frame(width: 22, height: 22)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// Elapsed time since `since`, updating only as often as the text changes.
private struct ElapsedText: View {
    enum Style { case clock, seconds }
    let since: Date
    let style: Style

    var body: some View {
        TimelineView(.periodic(from: since, by: style == .clock ? 1 : 0.1)) { context in
            Text(format(context.date.timeIntervalSince(since)))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
        }
    }

    private func format(_ elapsed: TimeInterval) -> String {
        let elapsed = max(0, elapsed)
        switch style {
        case .clock:
            let seconds = Int(elapsed)
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        case .seconds:
            return String(format: "%.1fs", elapsed)
        }
    }
}

/// Scrolling, symmetric bar waveform drawn with `Canvas` from a 60fps
/// `TimelineView`. The timeline only exists while recording, so nothing ticks
/// once the HUD moves on. Under Reduce Motion it becomes a non-scrolling
/// level bar redrawn at 15fps.
struct Waveform: View {
    let meter: MeterBox
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 15 : 1.0 / 60)) { timeline in
            Canvas { context, size in
                meter.meter.advance(to: timeline.date.timeIntervalSinceReferenceDate)
                if reduceMotion {
                    drawLevelBar(context: context, size: size)
                } else {
                    drawBars(context: context, size: size)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func drawBars(context: GraphicsContext, size: CGSize) {
        let state = meter.meter
        let count = state.capacity
        let pitch = size.width / CGFloat(count - 1)
        let barWidth = max(1.5, pitch * 0.55)
        let midY = size.height / 2
        // Sub-bar scroll so the strip glides instead of stepping a bar at a time.
        let offset = CGFloat(state.scrollPhase) * pitch
        state.forEachSample { index, sample in
            // The newest bar tracks the live level so the right edge reacts
            // instantly, not one sample interval later.
            let value = index == count - 1 ? state.level : sample
            let x = CGFloat(index) * pitch - offset
            guard x >= -barWidth else { return }
            // Fade the oldest bars into the capsule.
            let age = CGFloat(index) / CGFloat(count - 1)
            let height = max(2.5, size.height * CGFloat(value))
            let rect = CGRect(x: x - barWidth / 2, y: midY - height / 2, width: barWidth, height: height)
            context.fill(
                Path(roundedRect: rect, cornerRadius: barWidth / 2),
                with: .color(Color.accentColor.opacity(0.25 + 0.75 * Double(min(1, age * 1.6))))
            )
        }
    }

    private func drawLevelBar(context: GraphicsContext, size: CGSize) {
        let track = CGRect(x: 0, y: size.height / 2 - 3, width: size.width, height: 6)
        context.fill(Path(roundedRect: track, cornerRadius: 3), with: .color(Color.secondary.opacity(0.25)))
        var fill = track
        fill.size.width = max(6, size.width * CGFloat(meter.meter.level))
        context.fill(Path(roundedRect: fill, cornerRadius: 3), with: .color(.accentColor))
    }
}
