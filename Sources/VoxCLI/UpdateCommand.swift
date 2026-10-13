import ArgumentParser
import Foundation

struct Update: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Pull, rebuild, and reinstall the CLI and menu bar app.",
        discussion: """
            Updates a clean main checkout from origin, rebuilds both executables, \
            and restarts Vox if it was running. The checkout used to build this \
            CLI is the default; use --repo if it has moved. Use --no-pull to \
            reinstall your current local changes instead.
            """
    )

    @Option(help: "Source checkout (defaults to the checkout used to build this CLI).")
    var repo: String?

    @Option(help: "App bundle to update (defaults to the running copy, /Applications/Vox.app, or dist/Vox.app).")
    var app: String?

    @Flag(help: "Build the current checkout without pulling or updating submodules.")
    var noPull = false

    @Flag(help: "Leave the app closed after updating, even if it was running.")
    var noRestart = false

    @Flag(help: "Allow a signing identity change that may require granting app permissions again.")
    var allowPermissionReset = false

    func run() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repo.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL
        } ?? sourceRoot
        let script = root.appendingPathComponent("scripts/update.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw ValidationError("Source checkout not found at \(root.path). Use --repo /path/to/vox.")
        }

        var arguments = [script.path, "--repo", root.path]
        if let app {
            // Absolute, because the script runs from the checkout, not from here.
            let path = URL(fileURLWithPath: (app as NSString).expandingTildeInPath).standardizedFileURL.path
            arguments += ["--app", path]
        }
        // The script replaces this binary where it is installed, so a custom
        // PREFIX install is updated in place rather than at Homebrew's prefix.
        if let cli = Bundle.main.executableURL?.resolvingSymlinksInPath().path {
            arguments += ["--cli", cli]
        }
        if noPull { arguments.append("--no-pull") }
        if noRestart { arguments.append("--no-restart") }
        if allowPermissionReset { arguments.append("--allow-permission-reset") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = arguments
        // Preserve the terminal streams so git/build output and prompts are visible.
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ExitCode(process.terminationStatus) }
    }
}
