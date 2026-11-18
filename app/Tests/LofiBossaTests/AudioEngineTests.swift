import XCTest
@testable import LofiBossa

final class AudioEngineTests: XCTestCase {
    /// On macOS 27.2, changing an AVAudioSequencer that already had tracks (removeTrack, or
    /// clearEvents) never returns. That froze the app on the second version of any project and
    /// plausibly caused its random crashes. Loading must therefore build a fresh sequencer each
    /// time. The loads run off the main thread so a regression fails by timeout instead of
    /// hanging the test run.
    func testLoadingSeveralSongsInARowDoesNotHang() {
        let finished = expectation(description: "five loads")
        DispatchQueue.global().async {
            let audio = AudioEngine()
            var song = SongSnapshot.empty(style: .bossa, length: 20)
            for i in 0..<song.tracks.count {
                song.tracks[i].notes = (0..<8).map { Note(pitch: 48 + $0, start: Double($0), duration: 0.5, velocity: 90) }
            }
            for _ in 0..<5 { audio.load(song) }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 20)
    }
}
