import AppKit
import ServiceManagement
import SwiftUI
import VoxCore
import VoxKit

struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        TabView {
            GeneralSettings(state: state)
                .tabItem { Label("General", systemImage: "gearshape") }
            VocabularySettings(state: state)
                .tabItem { Label("Vocabulary", systemImage: "text.book.closed") }
            ModesSettings(state: state)
                .tabItem { Label("Modes", systemImage: "wand.and.stars") }
            OutputSettings(state: state)
                .tabItem { Label("Output", systemImage: "doc.on.clipboard") }
            FeedbackSettings(state: state)
                .tabItem { Label("Feedback", systemImage: "speaker.wave.2") }
        }
        .padding(16)
        .frame(minWidth: 600, minHeight: 440)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var state: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var downloadingModel: String?

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Model", selection: binding(\.model)) {
                    ForEach(ModelCatalog.all, id: \.id) { model in
                        Text("\(model.id) — \(sizeLabel(model))").tag(model.id)
                    }
                }
                if let downloadingModel {
                    Text("Downloading \(downloadingModel)…").font(.caption).foregroundStyle(.secondary)
                } else if !modelInstalled {
                    HStack {
                        Text("Not downloaded yet.").font(.caption).foregroundStyle(.secondary)
                        Button("Download now") { download() }
                    }
                }
                Picker("Language", selection: languageBinding) {
                    Text("Auto-detect").tag("auto")
                    Text("English").tag("en")
                    Text("Spanish").tag("es")
                    Text("French").tag("fr")
                    Text("German").tag("de")
                    Text("Portuguese").tag("pt")
                }
            }

            Section("Hotkey") {
                Toggle("Enable global hotkey", isOn: binding(\.hotkey.enabled))
                LabeledContent("Shortcut", value: HotkeyManager.displayString(state.config.hotkey))
                Picker("Activation", selection: activationBinding) {
                    Text("Press and hold").tag(HotkeyConfig.Activation.pressAndHold)
                    Text("Toggle").tag(HotkeyConfig.Activation.toggle)
                }
                Text("Change the key with `vox config set hotkey.key_code <code>`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recording") {
                LabeledContent("Max duration") {
                    Stepper(
                        "\(Int(state.config.recording.maxDurationSeconds))s",
                        value: binding(\.recording.maxDurationSeconds),
                        in: 5...900,
                        step: 5
                    )
                }
                Toggle("Stop on silence", isOn: silenceEnabledBinding)
                if state.config.recording.silenceTimeoutSeconds != nil {
                    LabeledContent("Silence timeout") {
                        Stepper(
                            String(format: "%.1fs", silenceTimeoutBinding.wrappedValue),
                            value: silenceTimeoutBinding,
                            in: 0.5...10,
                            step: 0.5
                        )
                    }
                    LabeledContent("Silence threshold") {
                        Stepper(
                            "\(Int(silenceThresholdBinding.wrappedValue)) dBFS",
                            value: silenceThresholdBinding,
                            in: -80...(-20),
                            step: 1
                        )
                    }
                    Text(
                        "Recording stops once the input stays below the threshold for the "
                            + "timeout. A less negative threshold (e.g. -35) treats quieter "
                            + "trailing sound as speech, so it takes longer to count as silence."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in setLaunchAtLogin(enabled) }
            }
        }
        .formStyle(.grouped)
    }

    private var modelInstalled: Bool {
        guard let model = state.config.resolvedModel else { return false }
        return ModelManager().isInstalled(model)
    }

    private func sizeLabel(_ model: WhisperModel) -> String {
        model.approximateSizeMB >= 1024
            ? String(format: "%.1f GB", Double(model.approximateSizeMB) / 1024)
            : "\(model.approximateSizeMB) MB"
    }

    private func download() {
        guard let model = state.config.resolvedModel else { return }
        downloadingModel = model.id
        Task {
            _ = try? await ModelManager().ensureAvailable(model)
            downloadingModel = nil
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Vox: could not update launch-at-login: \(error.localizedDescription)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { state.config.language ?? "auto" },
            set: { newValue in
                var config = state.config
                config.language = newValue == "auto" ? nil : newValue
                state.save(config)
            }
        )
    }

    private var activationBinding: Binding<HotkeyConfig.Activation> {
        binding(\.hotkey.activation)
    }

    private var silenceEnabledBinding: Binding<Bool> {
        Binding(
            get: { state.config.recording.silenceTimeoutSeconds != nil },
            set: { enabled in
                var config = state.config
                config.recording.silenceTimeoutSeconds = enabled ? 2.0 : nil
                state.save(config)
            }
        )
    }

    private var silenceTimeoutBinding: Binding<Double> {
        Binding(
            get: { state.config.recording.silenceTimeoutSeconds ?? 2.0 },
            set: { newValue in
                var config = state.config
                config.recording.silenceTimeoutSeconds = newValue
                state.save(config)
            }
        )
    }

    private var silenceThresholdBinding: Binding<Double> {
        binding(\.recording.silenceThresholdDB)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<VoxConfig, Value>) -> Binding<Value> {
        Binding(
            get: { state.config[keyPath: keyPath] },
            set: { newValue in
                var config = state.config
                config[keyPath: keyPath] = newValue
                state.save(config)
            }
        )
    }
}

private struct FeedbackSettings: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section("Sounds") {
                Toggle("Play sounds", isOn: binding(\.feedback.soundsEnabled))
                Group {
                    soundPicker("Recording starts", keyPath: \.feedback.startSound)
                    soundPicker("Recording stops", keyPath: \.feedback.stopSound)
                    soundPicker("Something fails", keyPath: \.feedback.errorSound)
                }
                .disabled(!state.config.feedback.soundsEnabled)
            }

            Section("On screen") {
                Toggle("Show waveform at the top of the screen", isOn: binding(\.feedback.showOverlay))
                Text("A click-through strip under the menu bar showing the microphone input while recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func soundPicker(
        _ label: String,
        keyPath: WritableKeyPath<VoxConfig, String?>
    ) -> some View {
        HStack {
            Picker(label, selection: soundBinding(keyPath)) {
                Text("None").tag("")
                ForEach(FeedbackConfig.systemSoundNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            Button {
                if let name = state.config[keyPath: keyPath] { NSSound(named: name)?.play() }
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .disabled(state.config[keyPath: keyPath] == nil)
        }
    }

    private func soundBinding(_ keyPath: WritableKeyPath<VoxConfig, String?>) -> Binding<String> {
        Binding(
            get: { state.config[keyPath: keyPath] ?? "" },
            set: { newValue in
                var config = state.config
                config[keyPath: keyPath] = newValue.isEmpty ? nil : newValue
                state.save(config)
            }
        )
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<VoxConfig, Value>) -> Binding<Value> {
        Binding(
            get: { state.config[keyPath: keyPath] },
            set: { newValue in
                var config = state.config
                config[keyPath: keyPath] = newValue
                state.save(config)
            }
        )
    }
}

private struct VocabularySettings: View {
    @ObservedObject var state: AppState
    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("One term per line. Terms are injected as whisper.cpp's initial prompt, biasing the decode itself rather than replacing text afterwards.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .border(Color.secondary.opacity(0.3))
            HStack {
                Text(promptPreview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Save") { save() }
            }
        }
        .onAppear { text = state.config.vocabulary.joined(separator: "\n") }
    }

    private var promptPreview: String {
        VocabInjector.initialPrompt(vocabulary: text.split(separator: "\n").map(String.init))
            ?? "No prompt will be sent."
    }

    private func save() {
        var config = state.config
        config.vocabulary = VocabInjector.normalize(text.split(separator: "\n").map(String.init))
        state.save(config)
        text = config.vocabulary.joined(separator: "\n")
    }
}

private struct ModesSettings: View {
    @ObservedObject var state: AppState
    @State private var selection: String?

    var body: some View {
        HSplitView {
            List(state.config.modes, id: \.name, selection: $selection) { mode in
                VStack(alignment: .leading) {
                    Text(mode.name)
                    Text(mode.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                }
                .tag(mode.name)
            }
            .frame(minWidth: 160)

            if let mode = state.config.modes.first(where: { $0.name == selection }) {
                ModeDetail(state: state, mode: mode)
            } else {
                Text("Select a mode.").foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
    }
}

private struct ModeDetail: View {
    @ObservedObject var state: AppState
    let mode: ModeDefinition
    @State private var prompt: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mode.name).font(.headline)
            Text(mode.description ?? "").font(.caption).foregroundStyle(.secondary)

            if mode.kind == .llm {
                Text("System prompt").font(.caption)
                TextEditor(text: $prompt)
                    .font(.system(.body, design: .monospaced))
                    .border(Color.secondary.opacity(0.3))
                Text("Sent to \(mode.model ?? state.config.llm.model) via \(state.config.llm.baseURL).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Save prompt") { savePrompt() }
                }
            } else {
                Text("Built-in mode with no prompt: \(mode.kind == .raw ? "returns the transcript untouched" : "applies local rule-based cleanup").")
                    .font(.callout)
            }

            Button("Make default") { makeDefault() }
                .disabled(state.config.defaultMode == mode.name)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { prompt = mode.prompt ?? "" }
        .onChange(of: mode.name) { _ in prompt = mode.prompt ?? "" }
    }

    private func savePrompt() {
        var config = state.config
        guard let index = config.modes.firstIndex(where: { $0.name == mode.name }) else { return }
        config.modes[index].prompt = prompt
        state.save(config)
    }

    private func makeDefault() {
        var config = state.config
        config.defaultMode = mode.name
        state.save(config)
    }
}

private struct OutputSettings: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section("Destination") {
                Picker("Deliver transcript to", selection: destinationBinding) {
                    Text("Clipboard").tag(OutputConfig.Destination.clipboard)
                    Text("Paste into frontmost app").tag(OutputConfig.Destination.autoPaste)
                    Text("Nowhere (history only)").tag(OutputConfig.Destination.none)
                }
                if state.config.output.destination == .autoPaste,
                    !OutputRouter.hasAccessibilityPermission
                {
                    HStack {
                        Text("Auto-paste needs Accessibility permission.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Grant…") { OutputRouter.promptForAccessibilityPermission() }
                    }
                }
            }

            Section("History") {
                Toggle("Keep a local transcript history", isOn: historyBinding)
                LabeledContent("Entries kept") {
                    Stepper(
                        "\(state.config.output.sessionHistoryLimit)",
                        value: sessionHistoryLimitBinding,
                        in: 10...500,
                        step: 10
                    )
                }
                Text("Stored at ~/Library/Application Support/Vox/sessions.json, newest first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear history now") { state.clearHistory() }
                    .disabled(state.history.isEmpty)
            }

            Section("LLM modes") {
                LabeledContent("Endpoint", value: state.config.llm.baseURL)
                LabeledContent("Default model", value: state.config.llm.model)
                Text("LLM modes route through this OpenAI-compatible endpoint. Change it with `vox config set llm.base_url`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var destinationBinding: Binding<OutputConfig.Destination> {
        Binding(
            get: {
                // stdout/json are CLI-only; show them as clipboard in the app.
                switch state.config.output.destination {
                case .stdout, .json: return .clipboard
                default: return state.config.output.destination
                }
            },
            set: { newValue in
                var config = state.config
                config.output.destination = newValue
                state.save(config)
            }
        )
    }

    private var historyBinding: Binding<Bool> {
        Binding(
            get: { state.config.output.keepSessionHistory },
            set: { newValue in
                var config = state.config
                config.output.keepSessionHistory = newValue
                state.save(config)
            }
        )
    }

    private var sessionHistoryLimitBinding: Binding<Int> {
        Binding(
            get: { state.config.output.sessionHistoryLimit },
            set: { newValue in
                var config = state.config
                config.output.sessionHistoryLimit = newValue
                state.save(config)
            }
        )
    }
}
