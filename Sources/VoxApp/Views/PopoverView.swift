import AppKit
import SwiftUI
import VoxKit

struct PopoverView: View {
    @ObservedObject var state: AppState
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            HStack(spacing: 8) {
                Button(action: { state.toggleDictation() }) {
                    Label(
                        state.status == .recording ? "Stop" : "Start dictation",
                        systemImage: state.status == .recording ? "stop.fill" : "mic.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.status == .processing)
            }

            if state.status == .recording {
                LevelMeter(levelDB: state.inputLevelDB)
            }

            Picker("Mode", selection: modeBinding) {
                ForEach(state.config.modes, id: \.name) { mode in
                    Text(mode.name).tag(mode.name)
                }
            }

            if let transcript = state.lastTranscript, !transcript.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last transcript").font(.caption).foregroundStyle(.secondary)
                    Text(transcript)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .font(.callout)
                    Button("Copy again") { state.copyToClipboard(transcript) }
                        .buttonStyle(.link)
                }
            }

            Divider()

            HStack {
                Button("Settings…", action: openSettings)
                Spacer()
                Button("Clear history") { state.clearHistory() }
                    .disabled(state.history.isEmpty)
            }
            .buttonStyle(.link)

            Button("Quit Vox") { NSApp.terminate(nil) }
                .buttonStyle(.link)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(statusText).font(.headline)
                Text("\(state.config.model) · \(HotkeyManager.displayString(state.config.hotkey))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var statusText: String {
        switch state.status {
        case .idle: return "Ready"
        case .recording: return "Recording…"
        case .processing: return "Transcribing…"
        case .failed(let message): return message
        }
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { state.config.defaultMode },
            set: { newValue in
                var config = state.config
                config.defaultMode = newValue
                state.save(config)
            }
        )
    }
}

/// Maps dBFS onto a bar so the user can tell the mic is actually picking them
/// up before they finish a sentence.
struct LevelMeter: View {
    let levelDB: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.08), value: fraction)
    }

    private var fraction: Double {
        // -60 dBFS (near-silence) to 0 dBFS (clipping).
        min(1, max(0, (levelDB + 60) / 60))
    }
}
