import ArgumentParser
import Foundation
import VoxCore
import VoxKit

struct RecordOptions: ParsableArguments {
    @OptionGroup var configOptions: ConfigOptions

    @Option(name: .shortAndLong, help: "Mode to apply. Defaults to the configured default mode.")
    var mode: String?

    @Option(help: "Model to use for this run, overriding the configured one.")
    var model: String?

    @Option(help: "Language code to pin, or 'auto' to detect.")
    var language: String?

    @Option(
        name: .shortAndLong,
        help: "Where the transcript goes: clipboard, autoPaste, stdout, json, or none."
    )
    var output: OutputConfig.Destination?

    @Option(name: .shortAndLong, help: "Stop recording after this many seconds.")
    var timeout: Double?

    @Option(help: "Write the captured audio to this WAV file.")
    var saveAudio: String?

    @Flag(help: "Pretty-print JSON output.")
    var pretty = false

    @Flag(name: .shortAndLong, help: "Suppress progress messages on stderr.")
    var quiet = false
}

extension OutputConfig.Destination: ExpressibleByArgument {
    public init?(argument: String) {
        // Accept auto_paste, auto-paste, and autoPaste equally.
        let normalized = argument.replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        guard
            let match = OutputConfig.Destination.allCases.first(where: {
                $0.rawValue.lowercased() == normalized
            })
        else { return nil }
        self = match
    }

    public static var allValueStrings: [String] {
        OutputConfig.Destination.allCases.map(\.rawValue)
    }
}

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record from the microphone and transcribe.",
        discussion: """
            Recording stops on silence, at --timeout, or on Ctrl+C (which still \
            transcribes what was captured).
            """
    )

    @OptionGroup var options: RecordOptions

    func run() async throws {
        try await RecordRunner(options: options, inputFile: nil).run()
    }
}

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe an existing audio file instead of the microphone.",
        discussion: """
            Uses the same pipeline, modes, and output routing as `vox record`, so \
            it is also the way to exercise Vox on a machine with no microphone.
            """
    )

    @Argument(help: "Audio file to transcribe.")
    var file: String

    @OptionGroup var options: RecordOptions

    func run() async throws {
        try await RecordRunner(
            options: options,
            inputFile: URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        ).run()
    }
}

/// Shared body of `record` and `transcribe`.
struct RecordRunner {
    let options: RecordOptions
    let inputFile: URL?

    func run() async throws {
        // Resolved before anything can fail so a failure is reported in the
        // shape the caller asked for.
        let requestedDestination = options.output
        do {
            let result = try await execute()
            if let rendered = result {
                Stdout.write(rendered)
            }
        } catch {
            let voxError = voxError(from: error)
            if requestedDestination == .json {
                let envelope = RecordEnvelope(error: voxError)
                Stdout.write((try? VoxJSON.string(envelope, pretty: options.pretty)) ?? #"{"ok":false}"#)
            } else {
                voxError.printToStderr()
            }
            throw ExitCode(voxError.exitCode)
        }
    }

    private func execute() async throws -> String? {
        var config = try options.configOptions.loadConfig()
        if let model = options.model {
            config.model = model
        }
        if let language = options.language {
            config.language = ConfigKeys.isUnset(language) ? nil : language
        }
        let destination = options.output ?? config.output.destination
        try config.validate()

        let paths = options.configOptions.paths
        let pipeline = DictationPipeline(config: config, paths: paths)
        let interrupt = InterruptHandler { pipeline.stopRecording() }
        interrupt.install()
        defer { interrupt.cancel() }

        let pipelineOptions = DictationPipeline.Options(
            modeName: options.mode,
            timeout: options.timeout,
            inputFile: inputFile,
            saveAudioTo: options.saveAudio.map {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
            }
        )

        let quiet = options.quiet
        let result = try await pipeline.run(options: pipelineOptions) { stage in
            guard !quiet else { return }
            switch stage {
            case .recording:
                Stderr.write("Recording… (silence or Ctrl+C to stop)")
            case .transcribing:
                Stderr.write("Transcribing…")
            case .processingMode(let mode):
                Stderr.write("Applying mode '\(mode)'…")
            case .finished:
                break
            }
        }

        let history = config.output.keepSessionHistory
            ? SessionHistory(paths: paths, limit: config.output.sessionHistoryLimit)
            : nil
        let router = OutputRouter(history: history)
        let rendered = try router.deliver(
            result: result,
            destination: destination,
            pretty: options.pretty
        )
        if !quiet, destination == .clipboard {
            Stderr.write("Copied \(result.transcript.count) characters to the clipboard.")
        }
        return rendered
    }
}

/// Turns the first Ctrl+C into "stop recording and transcribe what we have",
/// which is how a human ends an open-ended `vox record`. A second Ctrl+C
/// aborts.
final class InterruptHandler {
    private let onInterrupt: () -> Void
    private var source: DispatchSourceSignal?
    private var fired = false

    init(onInterrupt: @escaping () -> Void) {
        self.onInterrupt = onInterrupt
    }

    func install() {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if self.fired {
                Stderr.write("Aborted.")
                exit(VoxErrorCode.cancelled.exitCode)
            }
            self.fired = true
            Stderr.write("Stopping…")
            self.onInterrupt()
        }
        source.resume()
        self.source = source
    }

    func cancel() {
        source?.cancel()
        source = nil
        signal(SIGINT, SIG_DFL)
    }
}
