import AVFoundation

/// Plays a SongSnapshot: one sampler per track -> track mix -> low-pass -> reverb -> output,
/// with vinyl noise mixed in after the effects.
final class AudioEngine {
    enum ExportFormat { case wav, m4a }

    private let engine = AVAudioEngine()
    private var samplers: [TrackID: AVAudioUnitSampler] = [:]
    private let trackMix = AVAudioMixerNode()
    private let lowPass = AVAudioUnitEQ(numberOfBands: 1)
    private let reverb = AVAudioUnitReverb()
    private let vinyl = VinylNoise()
    private lazy var sequencer = AVAudioSequencer(audioEngine: engine)

    private static let soundBank = URL(
        fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
    /// The sequencer runs at 120 BPM, so one second is two beats.
    private static let beatsPerSecond = 2.0
    private(set) var seconds: Double = 0

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        for node in [trackMix, lowPass, reverb, vinyl.node] as [AVAudioNode] { engine.attach(node) }
        for id in TrackID.allCases {
            let sampler = AVAudioUnitSampler()
            engine.attach(sampler)
            engine.connect(sampler, to: trackMix, format: format)
            samplers[id] = sampler
        }
        engine.connect(trackMix, to: lowPass, format: format)
        engine.connect(lowPass, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
        engine.connect(vinyl.node, to: engine.mainMixerNode, format: format)

        lowPass.bands[0].filterType = .lowPass
        lowPass.bands[0].bypass = false
        reverb.loadFactoryPreset(.mediumRoom)
    }

    func start() throws {
        if !engine.isRunning { try engine.start() }
    }

    // MARK: Sound

    func setInstrument(_ program: UInt8, for id: TrackID) {
        let bank = id == .drums ? kAUSampler_DefaultPercussionBankMSB : kAUSampler_DefaultMelodicBankMSB
        try? samplers[id]?.loadSoundBankInstrument(
            at: Self.soundBank, program: program, bankMSB: UInt8(bank), bankLSB: 0)
    }

    func setVolume(_ volume: Double, for id: TrackID) {
        samplers[id]?.volume = Float(volume)
    }

    func apply(_ effects: MixEffects) {
        // warmth 0 -> 18 kHz (open), 1 -> 900 Hz (muffled), on a log scale
        lowPass.bands[0].frequency = Float(18000 * pow(900.0 / 18000.0, effects.warmth))
        reverb.wetDryMix = Float(effects.reverb * 60)
        vinyl.level = Float(effects.vinyl)
    }

    // MARK: Song and transport

    func load(_ snapshot: SongSnapshot) {
        sequencer.stop()
        for track in sequencer.tracks { sequencer.removeTrack(track) }
        sequencer.tempoTrack.addEvent(AVExtendedTempoEvent(tempo: 60 * Self.beatsPerSecond), at: 0)
        for id in TrackID.allCases {
            let track = sequencer.createAndAppendTrack()
            track.destinationAudioUnit = samplers[id]
            for note in snapshot.track(id).notes {
                let event = AVMIDINoteEvent(
                    channel: 0, key: UInt32(note.pitch), velocity: UInt32(note.velocity),
                    duration: note.duration * Self.beatsPerSecond)
                track.addEvent(event, at: note.start * Self.beatsPerSecond)
            }
        }
        seconds = snapshot.lengthSeconds
        sequencer.currentPositionInSeconds = 0
    }

    var isPlaying: Bool { sequencer.isPlaying }

    var position: Double {
        get { sequencer.currentPositionInSeconds }
        set { sequencer.currentPositionInSeconds = max(0, min(newValue, seconds)) }
    }

    func play() throws {
        try start()
        if position >= seconds { position = 0 }
        sequencer.prepareToPlay()
        try sequencer.start()
    }

    func stop() {
        sequencer.stop()
    }

    // MARK: Export

    /// Renders `range` (default: the whole song) through the current mix and effects, faster
    /// than real time.
    func export(to url: URL, format: ExportFormat, range: ClosedRange<Double>? = nil, tail: Double = 2.5) throws {
        stop()
        engine.stop()
        let renderFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: 4096)
        defer {
            sequencer.stop()
            engine.stop()
            engine.disableManualRenderingMode()
            sequencer.currentPositionInSeconds = 0
            try? engine.start()
        }
        try engine.start()
        let start = range?.lowerBound ?? 0
        let end = range?.upperBound ?? seconds
        sequencer.currentPositionInSeconds = start
        sequencer.prepareToPlay()
        try sequencer.start()

        var settings: [String: Any] = [AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2]
        switch format {
        case .wav:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
        case .m4a:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = 256_000
        }
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        let duration = max(end - start, 0) + tail
        let total = AVAudioFramePosition(duration * renderFormat.sampleRate)

        while engine.manualRenderingSampleTime < total {
            let frames = AVAudioFrameCount(
                min(Int64(buffer.frameCapacity), total - engine.manualRenderingSampleTime))
            switch try engine.renderOffline(frames, to: buffer) {
            case .success: try file.write(from: buffer)
            case .error: throw CocoaError(.fileWriteUnknown)
            default: break
            }
        }
    }

    func midiData() throws -> Data {
        var error: NSError?
        let data = sequencer.data(withSMPTEResolution: 0, error: &error)
        if let error { throw error }
        return data
    }
}
