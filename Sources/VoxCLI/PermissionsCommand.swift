import ArgumentParser
import Foundation
import VoxCore
import VoxKit

struct Permissions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "permissions",
        abstract: "Check (and optionally request) the permissions Vox needs.",
        discussion: """
            Microphone access is required. Accessibility is only needed for the \
            autoPaste output destination — the JSON/agent path needs neither a \
            GUI nor Accessibility.
            """
    )

    @Flag(help: "Trigger the system prompts for anything not yet granted.")
    var request = false

    func run() async throws {
        var allGranted = true

        let microphone = request
            ? await AudioCapture.requestPermission()
            : AudioCapture.hasPermission
        Stdout.write("microphone     \(microphone ? "granted" : "denied")")
        allGranted = allGranted && microphone

        let accessibility = OutputRouter.hasAccessibilityPermission
        Stdout.write("accessibility  \(accessibility ? "granted" : "not granted (only needed for autoPaste)")")
        if !accessibility && request {
            OutputRouter.promptForAccessibilityPermission()
            Stderr.write("Requested Accessibility access; approve it in System Settings, then re-run.")
        }

        guard allGranted else {
            throw ExitCode(VoxErrorCode.permission.exitCode)
        }
    }
}
