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

    func reset() {
        samples = Array(repeating: 0, count: Self.sampleCount)
        isProcessing = false
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
    private static let topMargin: CGFloat = 12

    func show() {
        model.reset()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
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

    func setProcessing(_ isProcessing: Bool) {
        model.isProcessing = isProcessing
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

struct RecordingOverlayView: View {
    @ObservedObject var model: WaveformModel

    var body: some View {
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
