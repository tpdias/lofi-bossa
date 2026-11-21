#if os(iOS)
import AVFoundation

/// The iOS audio session (docs/design/HANDOFF.md §8): `.playback`, so music plays with the
/// silent switch on and, with the `audio` background mode in the target's Info.plist, keeps
/// playing after the user leaves the app. Playback pauses on an interruption (a call, Siri, an
/// alarm) and when headphones are unplugged, and does not resume by itself afterwards.
@MainActor
final class AudioSessionController {
    static let shared = AudioSessionController()

    private var onPause: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    /// Sets the category and starts listening. `onPause` stops the transport (the app's
    /// AudioEngine is per project, so the caller pauses whichever project is open).
    func activate(onPause: @escaping () -> Void) {
        self.onPause = onPause
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("audio session: \(error.localizedDescription)")
        }
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session,
                                            queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init) == .began else { return }
            MainActor.assumeIsolated { self?.onPause?() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session,
                                            queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard raw.flatMap(AVAudioSession.RouteChangeReason.init) == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { self?.onPause?() }
        })
    }
}
#endif
