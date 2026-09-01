import AppKit
import VoxKit

/// Start/stop chimes, so a press-and-hold dictation is confirmed without
/// looking at the menu bar. Uses the stock macOS sounds — nothing is bundled.
@MainActor
final class FeedbackPlayer {
    var config: FeedbackConfig
    private var cache: [String: NSSound] = [:]

    init(config: FeedbackConfig) {
        self.config = config
    }

    func playStart() { play(config.startSound) }
    func playStop() { play(config.stopSound) }
    func playError() { play(config.errorSound) }

    private func play(_ name: String?) {
        guard config.soundsEnabled, let name else { return }
        let sound: NSSound?
        if let cached = cache[name] {
            sound = cached
        } else {
            sound = NSSound(named: name)
            cache[name] = sound
        }
        guard let sound else { return }
        // `play()` is a no-op while the sound is still playing, which a quick
        // start/stop would otherwise swallow.
        sound.stop()
        sound.play()
    }
}
