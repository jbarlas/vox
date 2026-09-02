import AppKit
import Combine
import SwiftUI

/// The rolling waveform shown while recording. Levels arrive from the capture
/// callback faster than the view needs them; the model keeps only what fits.
@MainActor
final class WaveformModel: ObservableObject {
    static let sampleCount = 56

    @Published private(set) var samples: [Double] = Array(repeating: 0, count: sampleCount)
    @Published var isProcessing = false
    /// Whether this recording shows the live preview line at all; decided at
    /// `show()` so the panel never resizes mid-dictation.
    @Published var showsPreview = false
    /// Low-confidence chunked text. Never the final transcript: it is cleared
    /// the moment recording stops and the full pass runs.
    @Published var previewText = ""

    func reset(showsPreview: Bool) {
        samples = Array(repeating: 0, count: Self.sampleCount)
        isProcessing = false
        self.showsPreview = showsPreview
        previewText = ""
    }

    /// dBFS is logarithmic and mostly empty below -60 for speech, so the bottom
    /// of the range is clamped rather than compressed.
    func push(levelDB: Double) {
        let normalized = min(1, max(0, (levelDB + 60) / 60))
        samples.removeFirst()
        samples.append(normalized)
    }
}

/// A borderless panel pinned under the menu bar: visible over full-screen apps,
/// never takes focus, and never eats a click.
@MainActor
final class RecordingOverlayController {
    private let model = WaveformModel()
    private var panel: NSPanel?

    private static let size = NSSize(width: 260, height: 44)
    private static let previewSize = NSSize(width: 460, height: 84)
    private static let topMargin: CGFloat = 12

    func show(withPreview showsPreview: Bool = false) {
        model.reset(showsPreview: showsPreview)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel, size: showsPreview ? Self.previewSize : Self.size)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func update(levelDB: Double) {
        model.push(levelDB: levelDB)
    }

    func update(previewText: String) {
        model.previewText = previewText
    }

    func setProcessing(_ isProcessing: Bool) {
        model.isProcessing = isProcessing
        if isProcessing { model.previewText = "" }
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
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
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.contentViewController = NSHostingController(rootView: RecordingOverlayView(model: model))
        panel.contentView?.wantsLayer = true
        return panel
    }

    /// Follows the screen the pointer is on, which is where the user is
    /// working — not necessarily the screen holding the menu bar.
    private func position(_ panel: NSPanel, size: NSSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - Self.topMargin
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }
}

struct RecordingOverlayView: View {
    @ObservedObject var model: WaveformModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: model.isProcessing ? "waveform" : "mic.fill")
                    .foregroundStyle(model.isProcessing ? Color.secondary : Color.red)
                    .font(.system(size: 13, weight: .semibold))

                if model.isProcessing {
                    Text("Transcribing…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Waveform(samples: model.samples)
                }
            }
            if model.showsPreview {
                LivePreviewLine(text: model.previewText, isProcessing: model.isProcessing)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
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
}

/// Deliberately styled as a guess: dimmed and italic, tail-anchored so the
/// newest words stay visible, and blank while the full pass runs so the
/// preview is never mistaken for the result.
struct LivePreviewLine: View {
    let text: String
    let isProcessing: Bool

    var body: some View {
        Text(displayText)
            .font(.system(size: 12))
            .italic()
            .foregroundStyle(.secondary)
            .opacity(text.isEmpty ? 0.5 : 0.8)
            .lineLimit(2)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayText: String {
        if isProcessing { return " " }
        return text.isEmpty ? "Listening…" : text
    }
}

/// Symmetric bars around a centre line, oldest to newest left to right, so the
/// strip reads like a waveform rather than a level meter.
struct Waveform: View {
    let samples: [Double]

    var body: some View {
        GeometryReader { geometry in
            let count = max(samples.count, 1)
            let spacing: CGFloat = 2
            let width = max(1, (geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(
                            width: width,
                            height: max(2, geometry.size.height * CGFloat(sample))
                        )
                }
            }
            .frame(height: geometry.size.height, alignment: .center)
            .animation(.linear(duration: 0.06), value: samples)
        }
        .frame(height: 22)
    }
}
