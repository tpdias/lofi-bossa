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

    /// Live playback must actually make sound. A second sequencer on the engine (created before
    /// the first song was loaded) once left it silent while transport, position and offline
    /// renders all looked fine, so this listens to the output instead of trusting `isPlaying`.
    func testLivePlaybackIsAudible() throws {
        let audio = AudioEngine()
        var song = SongSnapshot.empty(style: .bossa, length: 20)
        for i in 0..<song.tracks.count {
            song.tracks[i].notes = (0..<8).map { Note(pitch: 48 + $0, start: Double($0) * 0.5, duration: 0.4, velocity: 90) }
        }
        audio.load(song)
        var peak: Float = 0
        audio.outputNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
        }
        try audio.play()
        Thread.sleep(forTimeInterval: 1.5)
        audio.stop()
        XCTAssertGreaterThan(peak, 0.01, "the song played but nothing came out")
    }
}
