import AVFoundation

/// Puts the song under a video: reads the video's length, finds where someone is speaking so the
/// music can dip under it, and exports a copy of the video with the music mixed in. Everything
/// runs on the device with AVFoundation; nothing is uploaded.
enum VideoSoundtrack {
    struct Info: Equatable {
        var duration: Double
        var hasAudio: Bool
    }

    struct Options: Equatable {
        /// Music level against the video's own sound, 0...1.
        var musicVolume: Float = 0.6
        /// Lower the music while the video has speech or other loud sound.
        var duckUnderOriginal = true
        /// Seconds of fade-out at the end of the video.
        var fadeOut: Double = 2
    }

    /// Where the music is at a moment of the video: a volume that changes in a straight line
    /// between two of these.
    struct Keypoint: Equatable { var time: Double; var level: Float }

    static func info(for url: URL) async throws -> Info {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let audio = try await asset.loadTracks(withMediaType: .audio)
        return Info(duration: duration, hasAudio: !audio.isEmpty)
    }

    /// The length a song should have for a video: the project's generator accepts 15 to 180 s.
    static func songLength(forVideo seconds: Double) -> Double { min(max(seconds.rounded(), 15), 180) }

    // MARK: Ducking (pure, so it can be tested)

    /// Stretches of time where the loudness is above `threshold`, bridging pauses shorter than
    /// `bridge` (a breath between words is not a gap in the speech) and ignoring blips shorter
    /// than `minimum`. `loudness` has one value per `window` seconds.
    static func loudSegments(loudness: [Float], window: Double, threshold: Float,
                             bridge: Double = 0.6, minimum: Double = 0.2) -> [ClosedRange<Double>] {
        var segments: [ClosedRange<Double>] = []
        var start: Double?
        for (i, value) in loudness.enumerated() {
            let t = Double(i) * window
            if value >= threshold {
                if start == nil { start = t }
            } else if let s = start {
                segments.append(s...t); start = nil
            }
        }
        if let s = start { segments.append(s...(Double(loudness.count) * window)) }
        var merged: [ClosedRange<Double>] = []
        for seg in segments {
            if let last = merged.last, seg.lowerBound - last.upperBound < bridge {
                merged[merged.count - 1] = last.lowerBound...seg.upperBound
            } else { merged.append(seg) }
        }
        return merged.filter { $0.upperBound - $0.lowerBound >= minimum }
    }

    /// A loudness level that separates speech from the room: a fraction of the loud end of the
    /// recording, but never below a floor, so a silent video isn't treated as speech.
    static func duckingThreshold(for loudness: [Float]) -> Float {
        guard !loudness.isEmpty else { return .infinity }
        let sorted = loudness.sorted()
        let loud = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
        return max(0.01, loud * 0.3)
    }

    /// The music's volume over the video: `volume` normally, `volume * duckedFraction` while
    /// `speech` is going (eased in over `attack`, out over `release`), then down to silence
    /// over the last `fadeOut` seconds.
    static func gainKeypoints(duration: Double, volume: Float, speech: [ClosedRange<Double>],
                              duckedFraction: Float = 0.25, attack: Double = 0.2, release: Double = 0.6,
                              fadeOut: Double) -> [Keypoint] {
        let ducked = volume * duckedFraction
        var points = [Keypoint(time: 0, level: volume)]
        for seg in speech {
            let down = max(seg.lowerBound - attack, points.last!.time)
            let up = seg.upperBound
            guard up > down else { continue }
            points.append(Keypoint(time: down, level: volume))
            points.append(Keypoint(time: seg.lowerBound, level: ducked))
            points.append(Keypoint(time: up, level: ducked))
            points.append(Keypoint(time: up + release, level: volume))
        }
        if fadeOut > 0 {
            let fadeStart = max(duration - fadeOut, 0)
            var kept = points.filter { $0.time < fadeStart }
            kept.append(Keypoint(time: fadeStart, level: level(at: fadeStart, in: points)))
            kept.append(Keypoint(time: duration, level: 0))
            return kept
        }
        points.append(Keypoint(time: duration, level: level(at: duration, in: points)))
        return points.filter { $0.time <= duration }
    }

    static func level(at time: Double, in points: [Keypoint]) -> Float {
        guard let first = points.first else { return 1 }
        if time <= first.time { return first.level }
        for (a, b) in zip(points, points.dropFirst()) where time <= b.time {
            guard b.time > a.time else { return b.level }
            return a.level + (b.level - a.level) * Float((time - a.time) / (b.time - a.time))
        }
        return points.last!.level
    }

    /// Loudness (RMS) of the video's own sound, one value per `window` seconds.
    static func loudness(of asset: AVAsset, window: Double = 0.05) async throws -> [Float] {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let rate = 16000
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1, AVSampleRateKey: rate,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        let perWindow = Int(Double(rate) * window)
        var result: [Float] = []
        var sum: Double = 0
        var count = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var samples = [Int16](repeating: 0, count: length / 2)
            samples.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            for s in samples {
                let v = Double(s) / 32768
                sum += v * v; count += 1
                if count == perWindow { result.append(Float((sum / Double(count)).squareRoot())); sum = 0; count = 0 }
            }
        }
        return result
    }

    // MARK: Export

    /// Writes a copy of `video` to `destination` with the music file (a rendered WAV) mixed in.
    /// A song shorter than the video repeats; a longer one is cut at the end of the video.
    static func export(video: URL, music: URL, to destination: URL, options: Options) async throws {
        let source = AVURLAsset(url: video)
        let musicAsset = AVURLAsset(url: music)
        let duration = try await source.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)

        let composition = AVMutableComposition()
        guard let sourceVideo = try await source.loadTracks(withMediaType: .video).first,
              let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw CocoaError(.fileReadCorruptFile) }
        try videoTrack.insertTimeRange(range, of: sourceVideo, at: .zero)
        videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)

        var params: [AVMutableAudioMixInputParameters] = []
        if let original = try await source.loadTracks(withMediaType: .audio).first,
           let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try track.insertTimeRange(range, of: original, at: .zero)
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(1, at: .zero)
            params.append(p)
        }

        guard let sourceMusic = try await musicAsset.loadTracks(withMediaType: .audio).first,
              let musicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw CocoaError(.fileReadCorruptFile) }
        let musicLength = try await musicAsset.load(.duration)
        guard musicLength.seconds > 0 else { throw CocoaError(.fileReadCorruptFile) }
        var cursor = CMTime.zero
        while cursor < duration {
            let piece = min(musicLength, duration - cursor)
            try musicTrack.insertTimeRange(CMTimeRange(start: .zero, duration: piece), of: sourceMusic, at: cursor)
            cursor = cursor + piece
        }

        var speech: [ClosedRange<Double>] = []
        if options.duckUnderOriginal {
            let loud = try await loudness(of: source)
            speech = loudSegments(loudness: loud, window: 0.05, threshold: duckingThreshold(for: loud))
        }
        let points = gainKeypoints(duration: duration.seconds, volume: options.musicVolume, speech: speech,
                                   fadeOut: options.fadeOut)
        let musicParams = AVMutableAudioMixInputParameters(track: musicTrack)
        musicParams.setVolume(points[0].level, at: .zero)
        for (a, b) in zip(points, points.dropFirst()) where b.time > a.time {
            musicParams.setVolumeRamp(
                fromStartVolume: a.level, toEndVolume: b.level,
                timeRange: CMTimeRange(start: CMTime(seconds: a.time, preferredTimescale: 600),
                                       end: CMTime(seconds: b.time, preferredTimescale: 600)))
        }
        params.append(musicParams)
        let mix = AVMutableAudioMix()
        mix.inputParameters = params

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
        else { throw CocoaError(.fileWriteUnknown) }
        session.audioMix = mix
        try? FileManager.default.removeItem(at: destination)
        if #available(macOS 15, iOS 18, *) {
            try await session.export(to: destination, as: .mp4)
        } else {
            session.outputURL = destination
            session.outputFileType = .mp4
            await session.export()
            if let error = session.error { throw error }
        }
    }
}
