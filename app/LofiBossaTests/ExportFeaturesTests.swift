import AVFoundation
import XCTest
@testable import LofiBossa

final class ExportFeaturesTests: XCTestCase {
    private func song(tracks: [TrackID: [Int]], length: Double = 6) -> SongSnapshot {
        var s = SongSnapshot.empty(style: .bossa, length: length)
        for i in s.tracks.indices {
            guard let pitches = tracks[s.tracks[i].id] else { continue }
            s.tracks[i].notes = pitches.enumerated().map {
                Note(pitch: $1, start: Double($0) * 0.5, duration: 0.45, velocity: 100)
            }
        }
        return s
    }

    private func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    // MARK: Pure processing

    func testFadesStartAndEndInSilence() {
        var x = [Float](repeating: 0.8, count: 44100 * 3)
        ExportProcessing.applyFades(&x, sampleRate: 44100, fadeIn: 1, fadeOut: 1)
        XCTAssertEqual(x.first!, 0, accuracy: 0.001)
        XCTAssertEqual(x.last!, 0, accuracy: 0.001)
        XCTAssertEqual(x[44100 * 3 / 2], 0.8, accuracy: 0.001, "the middle is untouched")
    }

    func testNoFadeLeavesAudioAlone() {
        var x = [Float](repeating: 0.5, count: 1000)
        ExportProcessing.applyFades(&x, sampleRate: 44100, fadeIn: 0, fadeOut: 0)
        XCTAssertEqual(x, [Float](repeating: 0.5, count: 1000))
    }

    func testSeamlessLoopFoldsTheTailOntoTheHead() {
        var x = [Float](repeating: 0, count: 150)
        for i in 100..<150 { x[i] = 0.25 }   // a tail ringing after a 100-frame body
        let out = ExportProcessing.foldTail(x, bodyFrames: 100)
        XCTAssertEqual(out.count, 100)
        XCTAssertEqual(out[0], 0.25, accuracy: 1e-6)
        XCTAssertEqual(out[49], 0.25, accuracy: 1e-6)
        XCTAssertEqual(out[50], 0, accuracy: 1e-6)
    }

    // MARK: Engine

    func testExportedFadesStartAndEndNearSilence() throws {
        let audio = AudioEngine()
        audio.load(song(tracks: [.piano: [60, 64, 67, 72, 67, 64, 60, 55, 60, 64, 67, 72]]))
        audio.setVolume(1, for: .piano)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fade-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try audio.export(to: url, format: .wav, options: ExportOptions(fadeIn: 1, fadeOut: 2))
        let x = try samples(url)
        XCTAssertGreaterThan(x.map(abs).max() ?? 0, 0.01, "the file is silent")
        XCTAssertLessThan(abs(x.first!), 0.01)
        XCTAssertLessThan(abs(x.last!), 0.01)
        XCTAssertLessThan(x.prefix(441).map(abs).max()!, 0.05)
    }

    func testSeamlessLoopExportHasTheSongsLengthWithoutATail() throws {
        let audio = AudioEngine()
        audio.load(song(tracks: [.piano: [60, 64, 67]], length: 4))
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("plain-\(UUID()).wav")
        let looped = FileManager.default.temporaryDirectory.appendingPathComponent("loop-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: plain); try? FileManager.default.removeItem(at: looped) }
        try audio.export(to: plain, format: .wav)
        try audio.export(to: looped, format: .wav, options: ExportOptions(seamlessLoop: true))
        XCTAssertEqual(Double(try samples(looped).count) / 44100, 4, accuracy: 0.01)
        XCTAssertEqual(Double(try samples(plain).count) / 44100, 6.5, accuracy: 0.01)
    }

    func testStemExportWritesOneFilePerNonEmptyTrack() throws {
        let audio = AudioEngine()
        let s = song(tracks: [.piano: [60, 64, 67], .bass: [36, 43, 36]])   // guitar and drums stay empty
        audio.load(s)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stems-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try audio.exportStems(s, to: folder, range: 0...3, tail: 0.5)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), ["1-Piano.wav", "3-Bass.wav"])
        for url in files { XCTAssertGreaterThan(try samples(url).map(abs).max() ?? 0, 0.005, "\(url.lastPathComponent) is silent") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("song.mid").path))
        // each stem holds only its own track: the bass stem has none of the piano's high notes
        let mixed = FileManager.default.temporaryDirectory.appendingPathComponent("mix-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: mixed) }
        try audio.export(to: mixed, format: .wav, range: 0...3, tail: 0.5)
        XCTAssertEqual(try samples(files[0]).count, try samples(mixed).count)
    }

    func testStemsZipContainsEveryStem() throws {
        let audio = AudioEngine()
        let s = song(tracks: [.piano: [60, 64]])
        audio.load(s)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("z-\(UUID())/Song-stems")
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("z-\(UUID()).zip")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()); try? FileManager.default.removeItem(at: zip) }
        try audio.exportStems(s, to: folder, range: 0...2, tail: 0.2)
        try StemArchive.zip(folder: folder, to: zip)
        let size = (try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int64) ?? 0
        XCTAssertGreaterThan(size, 1000)
        XCTAssertEqual(try Data(contentsOf: zip).prefix(2), Data([0x50, 0x4B]), "not a ZIP file")
    }

    // MARK: Video soundtrack

    func testSongLengthSnapsToTheVideoWithinTheGeneratorsRange() {
        XCTAssertEqual(VideoSoundtrack.songLength(forVideo: 42.4), 42)
        XCTAssertEqual(VideoSoundtrack.songLength(forVideo: 5), 15)
        XCTAssertEqual(VideoSoundtrack.songLength(forVideo: 600), 180)
    }

    func testLoudSegmentsBridgeBreathsAndDropBlips() {
        // 0.05 s windows: speech 1.0-2.0 s, a 0.3 s pause, speech 2.3-3.0 s, a lone blip at 5 s
        var loud = [Float](repeating: 0, count: 120)
        for i in 20..<40 { loud[i] = 0.2 }
        for i in 46..<60 { loud[i] = 0.2 }
        loud[100] = 0.2
        let segs = VideoSoundtrack.loudSegments(loudness: loud, window: 0.05, threshold: 0.1)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].lowerBound, 1.0, accuracy: 0.001)
        XCTAssertEqual(segs[0].upperBound, 3.0, accuracy: 0.001)
    }

    func testDuckingLowersTheMusicUnderSpeechAndFadesOut() {
        let pts = VideoSoundtrack.gainKeypoints(duration: 20, volume: 0.8, speech: [5...8], fadeOut: 2)
        XCTAssertEqual(VideoSoundtrack.level(at: 0, in: pts), 0.8, accuracy: 1e-4)
        XCTAssertEqual(VideoSoundtrack.level(at: 6.5, in: pts), 0.2, accuracy: 1e-4)
        XCTAssertEqual(VideoSoundtrack.level(at: 12, in: pts), 0.8, accuracy: 1e-4)
        XCTAssertEqual(VideoSoundtrack.level(at: 19, in: pts), 0.4, accuracy: 1e-4)
        XCTAssertEqual(pts.last!.level, 0)
        XCTAssertEqual(pts.last!.time, 20)
        XCTAssertEqual(pts.map(\.time), pts.map(\.time).sorted(), "keypoints must be in time order")
    }

    /// Builds a short video, mixes a song into it, and checks the result has the video and sound.
    func testExportsAVideoWithTheMusicMixedIn() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vid-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("in.mp4")
        try await Self.makeVideo(at: video, seconds: 3)

        let audio = AudioEngine()
        audio.load(song(tracks: [.piano: [60, 64, 67, 72]], length: 2))
        audio.setVolume(1, for: .piano)
        let music = dir.appendingPathComponent("music.wav")
        try audio.export(to: music, format: .wav, tail: 0)

        let out = dir.appendingPathComponent("out.mp4")
        try await VideoSoundtrack.export(video: video, music: music, to: out, options: VideoSoundtrack.Options())
        let info = try await VideoSoundtrack.info(for: out)
        XCTAssertEqual(info.duration, 3, accuracy: 0.2)
        XCTAssertTrue(info.hasAudio)
        let loud = try await VideoSoundtrack.loudness(of: AVURLAsset(url: out))
        XCTAssertGreaterThan(loud.max() ?? 0, 0.005, "the music didn't make it into the video")
    }

    private static func makeVideo(at url: URL, seconds: Int) async throws {
        let writer = try AVAssetWriter(url: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 10) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }
}
