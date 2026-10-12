import AppKit
import GitokenCore
import os

/// Plays the bundled arrival sounds. Sounds are decoded once at launch; `NSSound.play()` returns immediately and
/// never activates the app, so playing from the notch does not steal focus.
@MainActor
final class SoundPlayer {
    static let log = Logger(subsystem: "io.github.benzara-tahar.Gitoken", category: "sound")

    private var sounds: [ArrivalSound: NSSound] = [:]
    private var readySound: NSSound?

    init(bundle: Bundle = .main) {
        if let url = bundle.url(forResource: "Ready", withExtension: "caf") {
            readySound = NSSound(contentsOf: url, byReference: false)
        }
        for sound in ArrivalSound.allCases {
            guard let name = sound.resourceName else { continue }
            guard let url = bundle.url(forResource: name, withExtension: "caf"),
                  let loaded = NSSound(contentsOf: url, byReference: false)
            else {
                Self.log.error("Missing sound resource \(name, privacy: .public).caf")
                continue
            }
            sounds[sound] = loaded
        }
    }

    func playReady(volume: Double) {
        readySound?.stop()
        readySound?.volume = Float(min(1, max(0, volume)))
        readySound?.play()
    }

    func play(_ sound: ArrivalSound, volume: Double, reason: String) {
        guard let player = sounds[sound] else { return }
        player.stop()
        player.volume = Float(min(1, max(0, volume)))
        player.play()
        Self.log.notice("Play \(sound.rawValue, privacy: .public) at \(volume, format: .fixed(precision: 2)) for \(reason, privacy: .public)")
    }
}
