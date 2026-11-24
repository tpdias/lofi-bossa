import AVFoundation
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

    func testPlayingAfterReloadingASongIsAudible() throws {
        let audio = AudioEngine()
        var song = SongSnapshot.empty(style: .bossa, length: 20)
        for i in 0..<song.tracks.count {
            song.tracks[i].notes = (0..<8).map { Note(pitch: 48 + $0, start: Double($0) * 0.5, duration: 0.4, velocity: 90) }
        }
        var peak: Float = 0
        audio.outputNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
        }
        audio.load(song)
        for t in song.tracks { audio.setInstrument(t.id.program(for: t.instrument), for: t.id); audio.setVolume(0.7, for: t.id); audio.apply(t.effects, for: t.id) }
        try audio.play()
        Thread.sleep(forTimeInterval: 0.3)
        peak = 0
        Thread.sleep(forTimeInterval: 0.5)
        let first = peak
        audio.load(song)          // switching version while playing
        for t in song.tracks { audio.setInstrument(t.id.program(for: t.instrument), for: t.id); audio.setVolume(0.7, for: t.id); audio.apply(t.effects, for: t.id) }
        try audio.play()
        Thread.sleep(forTimeInterval: 0.3)
        peak = 0
        Thread.sleep(forTimeInterval: 1.5)
        audio.stop()
        // Compared with the same song before the reload, not with a fixed level: these low notes
        // on the real instruments are quiet, and this test once passed only because a reload
        // swapped them for the samplers' loud default tone (see testReloadingWhilePlayingKeepsTheInstrument).
        XCTAssertGreaterThan(first, 0.0005)
        XCTAssertGreaterThan(peak, first * 0.5, "silent after reloading a song")
    }

    /// The vinyl is part of the song: heard while it plays, silent when it is stopped.
    // MARK: Instruments survive an engine restart

    private func pianoSong() -> SongSnapshot {
        var song = SongSnapshot.empty(style: .lofi, length: 30)
        let i = song.tracks.firstIndex { $0.id == .piano }!
        song.tracks[i].notes = (0..<60).map { Note(pitch: 60 + $0 % 7, start: Double($0) * 0.5, duration: 0.4, velocity: 90) }
        return song
    }

    private func pianoEngine() -> AudioEngine {
        let audio = AudioEngine()
        audio.load(pianoSong())
        audio.setInstrument(TrackID.piano.program(for: "Electric Piano"), for: .piano)
        audio.setVolume(0.7, for: .piano)
        audio.apply(MixEffects(warmth: 0.6, reverb: 0.3, vinyl: 0))   // no vinyl: its random pops skew levels
        return audio
    }

    /// Loudness (the loudest 2048-frame RMS) of the output over `seconds`.
    private func level(_ audio: AudioEngine, _ seconds: Double) -> Float {
        var level: Float = 0
        audio.outputNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
            guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
            level = max(level, (sum / Float(buffer.frameLength)).squareRoot())
        }
        Thread.sleep(forTimeInterval: seconds)
        audio.outputNode.removeTap(onBus: 0)
        return level
    }

    /// Reloading the song while it plays (adding a track, a rewrite, undo, a version switch)
    /// restarts the engine, which reset every sampler to its default sine tone: the piano came
    /// back about three times louder and stayed that way until the app restarted.
    func testReloadingWhilePlayingKeepsTheInstrument() throws {
        let audio = pianoEngine()
        try audio.play()
        Thread.sleep(forTimeInterval: 0.3)
        let before = level(audio, 1.5)
        audio.load(pianoSong())
        try audio.play()
        Thread.sleep(forTimeInterval: 0.3)
        let after = level(audio, 1.5)
        audio.stop()
        XCTAssertGreaterThan(before, 0.005)
        XCTAssertEqual(after, before, accuracy: before * 0.25, "the piano changed after reloading the song")
    }

    /// The same reset hit exports: every export after the first (or after playing) was the sine.
    func testExportingTwiceSoundsTheSame() throws {
        let audio = pianoEngine()
        let dir = FileManager.default.temporaryDirectory
        let first = dir.appendingPathComponent("lfb-export-1-\(UUID()).wav")
        let second = dir.appendingPathComponent("lfb-export-2-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        try audio.export(to: first, format: .wav, range: 0...4)
        try audio.export(to: second, format: .wav, range: 0...4)
        func rms(_ url: URL) throws -> Float {
            let file = try AVAudioFile(forReading: url)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            let data = buffer.floatChannelData![0]
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
            return (sum / Float(max(buffer.frameLength, 1))).squareRoot()
        }
        let a = try rms(first), b = try rms(second)
        XCTAssertGreaterThan(a, 0.001)
        XCTAssertEqual(b, a, accuracy: a * 0.1, "the second export sounded different from the first")
    }

    func testVinylOnlyPlaysWhileTheSongPlays() throws {
        let audio = AudioEngine()
        audio.apply(MixEffects(warmth: 0, reverb: 0, vinyl: 1))
        audio.load(SongSnapshot.empty(style: .lofi, length: 10))   // no notes: only vinyl can make sound
        func peak(_ seconds: Double) -> Float {
            var peak: Float = 0
            audio.outputNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
                guard let data = buffer.floatChannelData?[0] else { return }
                for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
            }
            Thread.sleep(forTimeInterval: seconds)
            audio.outputNode.removeTap(onBus: 0)
            return peak
        }
        try audio.start()
        XCTAssertEqual(peak(0.6), 0, accuracy: 0.0001, "vinyl is audible before play")
        try audio.play()
        XCTAssertGreaterThan(peak(0.8), 0.001, "no vinyl while playing")
        audio.stop()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(peak(0.6), 0, accuracy: 0.0001, "vinyl keeps playing after stop")
    }
}
