import AVFoundation

/// Plays a SongSnapshot: one sampler per track -> track mix -> low-pass -> reverb -> output,
/// with vinyl noise mixed in after the effects.
final class AudioEngine {
    enum ExportFormat { case wav, m4a }

    private let engine = AVAudioEngine()
    private var samplers: [TrackID: AVAudioUnitSampler] = [:]
    private var chains: [TrackID: TrackChain] = [:]
    private var loadedPrograms: [TrackID: UInt8] = [:]
    private let trackMix = AVAudioMixerNode()
    private let lowPass = AVAudioUnitEQ(numberOfBands: 1)
    private let reverb = AVAudioUnitReverb()
    private let vinyl = VinylNoise()
    /// Created by `load` and nowhere else. It must not exist before the first song: a second
    /// sequencer on the same engine (the one a lazy property made just to be stopped, then
    /// replaced) left the real one silent in live playback while offline renders still worked.
    private var sequencer: AVAudioSequencer?

    private static let soundBank = URL(
        fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
    /// The sequencer runs at 120 BPM, so one second is two beats.
    private static let beatsPerSecond = 2.0
    private(set) var seconds: Double = 0

    /// The vinyl noise is part of the song's sound, so it only plays while the song does (or while
    /// an export is rendering). `vinylLevel` is the user's setting; the gate decides if it's heard.
    private var vinylLevel: Float = 0
    private var vinylGate = false {
        didSet { vinyl.level = vinylGate ? vinylLevel : 0 }
    }

    /// One track's effects, in signal order: sampler -> eq -> distortion -> delay -> reverb ->
    /// pan. The pan stage is a mixer node because pan belongs to a node's connection into a
    /// mixer (AVAudioMixing), and plain effect units don't carry it.
    private struct TrackChain {
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        let distortion = AVAudioUnitDistortion()
        let delay = AVAudioUnitDelay()
        let reverb = AVAudioUnitReverb()
        let pan = AVAudioMixerNode()

        var nodes: [AVAudioNode] { [eq, distortion, delay, reverb, pan] }

        init() {
            eq.bands[0].filterType = .lowPass
            eq.bands[0].bypass = false
            distortion.loadFactoryPreset(.multiDecimated2)
            delay.delayTime = 0.375
            delay.feedback = 35
            delay.lowPassCutoff = 6000
            reverb.loadFactoryPreset(.mediumRoom)
        }
    }

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        for node in [trackMix, lowPass, reverb, vinyl.node] as [AVAudioNode] { engine.attach(node) }
        for id in TrackID.allCases {
            let sampler = AVAudioUnitSampler()
            let chain = TrackChain()
            engine.attach(sampler)
            for node in chain.nodes { engine.attach(node) }
            let path: [AVAudioNode] = [sampler] + chain.nodes + [trackMix]
            for (from, to) in zip(path, path.dropFirst()) { engine.connect(from, to: to, format: format) }
            samplers[id] = sampler
            chains[id] = chain
            apply(TrackEffects(), for: id)
        }
        engine.connect(trackMix, to: lowPass, format: format)
        engine.connect(lowPass, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
        engine.connect(vinyl.node, to: engine.mainMixerNode, format: format)

        lowPass.bands[0].filterType = .lowPass
        lowPass.bands[0].bypass = false
        reverb.loadFactoryPreset(.mediumRoom)
    }

    /// For tests that listen to the output.
    var outputNode: AVAudioNode { engine.mainMixerNode }

    func start() throws {
        if !engine.isRunning { try engine.start() }
    }

    // MARK: Sound

    /// Plays one note on a track's own sound and effects for a moment (auditioning a note while
    /// editing). Works whether or not the song is playing.
    func preview(pitch: Int, velocity: Int, track id: TrackID, length: Double = 0.35) {
        guard (0...127).contains(pitch), let sampler = samplers[id] else { return }
        try? start()
        let note = UInt8(pitch)
        sampler.startNote(note, withVelocity: UInt8(min(max(velocity, 1), 127)), onChannel: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + length) { sampler.stopNote(note, onChannel: 0) }
    }

    /// Loads a track's instrument, unless it already has it. Reloading the sound bank on a
    /// sampler whose engine is running (which every version switch used to do) left the new
    /// sequencer's notes silent and playback dead until the app was restarted.
    func setInstrument(_ program: UInt8, for id: TrackID) {
        guard loadedPrograms[id] != program else { return }
        loadedPrograms[id] = program
        let bank = id == .drums ? kAUSampler_DefaultPercussionBankMSB : kAUSampler_DefaultMelodicBankMSB
        try? samplers[id]?.loadSoundBankInstrument(
            at: Self.soundBank, program: program, bankMSB: UInt8(bank), bankLSB: 0)
    }

    func setVolume(_ volume: Double, for id: TrackID) {
        samplers[id]?.volume = Float(volume)
    }

    /// Sets one track's effects. A stage at zero is bypassed, so an untouched track is
    /// exactly the unprocessed sampler (and costs nothing).
    func apply(_ effects: TrackEffects, for id: TrackID) {
        guard let chain = chains[id] else { return }
        chain.eq.bypass = effects.warmth <= 0
        chain.eq.bands[0].frequency = Float(18000 * pow(900.0 / 18000.0, effects.warmth))
        chain.distortion.bypass = effects.grit <= 0
        chain.distortion.wetDryMix = Float(effects.grit * 100)
        chain.delay.bypass = effects.echo <= 0
        chain.delay.wetDryMix = Float(effects.echo * 60)
        chain.reverb.bypass = effects.reverb <= 0
        chain.reverb.wetDryMix = Float(effects.reverb * 60)
        chain.pan.pan = Float(min(max(effects.pan, -1), 1))
    }

    func apply(_ effects: MixEffects) {
        // warmth 0 -> 18 kHz (open), 1 -> 900 Hz (muffled), on a log scale
        lowPass.bands[0].frequency = Float(18000 * pow(900.0 / 18000.0, effects.warmth))
        reverb.wetDryMix = Float(effects.reverb * 60)
        vinylLevel = Float(effects.vinyl)
        vinyl.level = vinylGate ? vinylLevel : 0
    }

    // MARK: Song and transport

    func load(_ snapshot: SongSnapshot) {
        if let old = sequencer {
            old.stop()
            for track in old.tracks { track.destinationAudioUnit = nil }
        }
        sequencer = nil   // release the old one before making the new one
        // The engine must be stopped while the sequencer is swapped: replacing it on a running
        // engine (every version switch, undo or edit while playing) left the new sequencer
        // silent, with only the vinyl noise audible, until the app restarted.
        let wasRunning = engine.isRunning
        engine.stop()
        // Every song gets a brand-new sequencer, never an edited one. On macOS 27.2.1, changing
        // a sequencer that already has tracks is unreliable: removeTrack raised an NSRangeException
        // from inside AVAudioSequencer ("range {2, 1} extends beyond bounds [0 .. 1]", even when
        // iterating a copy of the tracks), and clearing the tempo track never returned. The app
        // hit this on the second song loaded into a project, as a freeze or a crash. Building a
        // sequencer from scratch is the path that works; the old one is simply released.
        let sequencer = AVAudioSequencer(audioEngine: engine)
        self.sequencer = sequencer
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
        if wasRunning { try? engine.start() }
    }

    var isPlaying: Bool { sequencer?.isPlaying ?? false }

    var position: Double {
        get { sequencer?.currentPositionInSeconds ?? 0 }
        set { sequencer?.currentPositionInSeconds = max(0, min(newValue, seconds)) }
    }

    func play() throws {
        guard let sequencer else { return }
        try start()
        if position >= seconds { position = 0 }
        sequencer.prepareToPlay()
        try sequencer.start()
        vinylGate = true
    }

    func stop() {
        sequencer?.stop()
        vinylGate = false
    }

    // MARK: Export

    /// Renders `range` (default: the whole song) through the current mix and effects, faster
    /// than real time.
    func export(to url: URL, format: ExportFormat, range: ClosedRange<Double>? = nil, tail: Double = 2.5) throws {
        guard let sequencer else { return }
        stop()
        vinylGate = true   // the file should have the vinyl, even though nothing plays live
        engine.stop()
        let renderFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: 4096)
        defer {
            vinylGate = false
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
        guard let sequencer else { return Data() }
        var error: NSError?
        let data = sequencer.data(withSMPTEResolution: 0, error: &error)
        if let error { throw error }
        return data
    }
}
