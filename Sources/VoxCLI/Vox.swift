import ArgumentParser
import Foundation
import VoxKit

@main
struct Vox: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vox",
        abstract: "Local, offline speech-to-text with a scriptable JSON interface.",
        discussion: """
            Vox records from the microphone, transcribes locally with whisper.cpp, \
            and routes the result to the clipboard, the frontmost app, or stdout.

            For agent use, `vox record --output json` prints a single JSON object \
            and exits nonzero on failure:

              result=$(vox record --output json --mode raw --timeout 30)
            """,
        version: VoxVersion.current,
        subcommands: [
            Record.self,
            Transcribe.self,
            ConfigCommand.self,
            Models.self,
            Modes.self,
            VocabCommand.self,
            Permissions.self,
        ],
        defaultSubcommand: Record.self
    )
}

enum VoxVersion {
    static let current = "0.1.0"
}
