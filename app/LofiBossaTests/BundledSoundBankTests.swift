import AVFoundation
import XCTest
@testable import LofiBossa

/// iOS has no system GM bank, so the iOS app plays GeneralUser GS from its bundle. These tests
/// load that same file on the Mac through the same `loadSoundBankInstrument` path and listen to
/// the result: every instrument must exist in the bank, and switching one must change the sound
/// (without a bank, every program falls back to the sampler's one default tone).
final class BundledSoundBankTests: XCTestCase {
    static let bank = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SoundBank/GeneralUser-GS.sf2")

    func testEveryInstrumentLoadsFromTheBundledBank() throws {
        for id in TrackID.allCases {
            for option in id.instruments {
                let sampler = AVAudioUnitSampler()
                let bank = id == .drums ? kAUSampler_DefaultPercussionBankMSB : kAUSampler_DefaultMelodicBankMSB
                XCTAssertNoThrow(
                    try sampler.loadSoundBankInstrument(
                        at: Self.bank, program: option.program, bankMSB: UInt8(bank), bankLSB: 0),
                    "\(id.rawValue): \(option.name) (program \(option.program)) is not in the bank")
            }
        }
    }

    func testChangingAnInstrumentChangesTheSound() throws {
        let piano = try BankRender.render(bank: Self.bank, track: .piano, program: TrackID.piano.program(for: "Grand Piano"))
        let vibes = try BankRender.render(bank: Self.bank, track: .piano, program: TrackID.piano.program(for: "Vibraphone"))
        let brush = try BankRender.render(bank: Self.bank, track: .drums, program: TrackID.drums.program(for: "Brush Kit"))
        let standard = try BankRender.render(bank: Self.bank, track: .drums, program: TrackID.drums.program(for: "Standard Kit"))
        for (name, samples) in [("piano", piano), ("vibes", vibes), ("brush", brush), ("standard", standard)] {
            XCTAssertGreaterThan(BankRender.rms(samples), 0.005, "\(name) is silent")
        }
        XCTAssertGreaterThan(BankRender.difference(piano, vibes), 0.3, "Grand Piano and Vibraphone sound the same")
        XCTAssertGreaterThan(BankRender.difference(brush, standard), 0.3, "Brush Kit and Standard Kit sound the same")
    }
}

/// Offline render of one track playing a short phrase with one program, everything else dry.
enum BankRender {
    static func render(bank: URL, track: TrackID, program: UInt8) throws -> [Float] {
        let audio = AudioEngine(soundBank: bank)
        audio.apply(MixEffects(warmth: 0, reverb: 0, vinyl: 0))
        var song = SongSnapshot.empty(style: .bossa, length: 4)
        let pitches = track == .drums ? [36, 38, 42, 46, 36, 38, 42, 49] : [60, 64, 67, 72, 67, 64, 60, 55]
        for i in song.tracks.indices where song.tracks[i].id == track {
            song.tracks[i].notes = pitches.enumerated().map {
                Note(pitch: $1, start: Double($0) * 0.4, duration: 0.35, velocity: 100)
            }
        }
        audio.load(song)
        audio.setInstrument(program, for: track)
        audio.setVolume(1, for: track)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bank-\(track.rawValue)-\(program)-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try audio.export(to: url, format: .wav, tail: 0.5)
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    static func rms(_ x: [Float]) -> Float {
        (x.reduce(0) { $0 + $1 * $1 } / Float(max(x.count, 1))).squareRoot()
    }

    /// RMS of the sample-wise difference relative to the louder render: 0 for identical audio,
    /// around 1 or more for unrelated sounds.
    static func difference(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        let diff = (0..<n).map { a[$0] - b[$0] }
        return rms(diff) / max(rms(a), rms(b), 1e-9)
    }
}
