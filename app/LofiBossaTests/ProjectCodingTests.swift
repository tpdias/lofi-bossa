import XCTest
@testable import LofiBossa

final class ProjectCodingTests: XCTestCase {
    private func makeProject() -> Project {
        var snapshot = SongSnapshot.empty(style: .lofi, length: 30)
        snapshot.tracks[0].notes = [Note(pitch: 60, start: 1, duration: 0.5, velocity: 90)]
        snapshot.tracks[0].effects = TrackEffects(warmth: 0.4, grit: 0.2, echo: 0.1, reverb: 0.3, pan: -0.5)
        var project = Project(name: "Test")
        let version = Version(number: 1, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                              kind: .newTake(seed: 7), changedTracks: Set(TrackID.allCases), snapshot: snapshot)
        project.versions = [version]
        project.currentVersionID = version.id
        return project
    }

    private func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
    private func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    func testRoundTripKeepsTrackEffects() throws {
        let project = makeProject()
        let decoded = try decoder().decode(Project.self, from: encoder().encode(project))
        XCTAssertEqual(decoded.currentSnapshot?.tracks[0].effects, project.currentSnapshot?.tracks[0].effects)
        XCTAssertEqual(decoded.currentSnapshot?.tracks[0].notes.count, 1)
    }

    /// A project saved before per-track effects existed has no "effects" key on its tracks.
    /// It must still load (with neutral effects), not fail and vanish from the library.
    func testProjectSavedBeforeTrackEffectsStillLoads() throws {
        let data = try encoder().encode(makeProject())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var versions = try XCTUnwrap(json["versions"] as? [[String: Any]])
        for v in versions.indices {
            var snapshot = try XCTUnwrap(versions[v]["snapshot"] as? [String: Any])
            var tracks = try XCTUnwrap(snapshot["tracks"] as? [[String: Any]])
            for t in tracks.indices { tracks[t].removeValue(forKey: "effects") }
            snapshot["tracks"] = tracks
            versions[v]["snapshot"] = snapshot
        }
        json["versions"] = versions
        let old = try JSONSerialization.data(withJSONObject: json)
        // Sanity-check the setup itself: no track in the JSON may still carry an "effects" key.
        let check = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
        let checkTracks = ((check["versions"] as? [[String: Any]])?.first?["snapshot"] as? [String: Any])?["tracks"] as? [[String: Any]]
        XCTAssertEqual(checkTracks?.count, 4)
        XCTAssertTrue(checkTracks?.allSatisfy { $0["effects"] == nil } ?? false, "test setup should have removed per-track effects")

        let decoded = try decoder().decode(Project.self, from: old)
        let tracks = try XCTUnwrap(decoded.currentSnapshot?.tracks)
        XCTAssertEqual(tracks.count, 4)
        XCTAssertTrue(tracks.allSatisfy { $0.effects.isNeutral })
        XCTAssertEqual(tracks[0].notes.count, 1, "notes must survive")
    }

    func testStyleDefaultTrackEffects() {
        XCTAssertFalse(SongSnapshot.empty(style: .lofi, length: 30).track(.drums).effects.isNeutral)
        XCTAssertTrue(SongSnapshot.empty(style: .lofi, length: 30).track(.bass).effects.isNeutral)
        XCTAssertFalse(SongSnapshot.empty(style: .bossa, length: 30).track(.guitar).effects.isNeutral)
    }

    func testNewVersionKindsRoundTripAndHaveTitles() throws {
        let kinds: [VersionKind] = [.sectionEdit(.guitar, "Cut guitar 0:10–0:18"),
                                    .rewriteSection(.bass, start: 5, end: 10)]
        for kind in kinds {
            let decoded = try JSONDecoder().decode(VersionKind.self, from: JSONEncoder().encode(kind))
            XCTAssertEqual(decoded, kind)
        }
        XCTAssertEqual(kinds[0].title, "Cut guitar 0:10–0:18")
        XCTAssertEqual(kinds[1].title, "Rewrote bass 0:05–0:10")
    }

    func testSongWithAddedTracksRoundTripsAndKeepsOrder() throws {
        var snapshot = SongSnapshot.empty(style: .bossa, length: 30, tracks: TrackID.core + [.vibes, .lead])
        snapshot.tracks[5].notes = [Note(pitch: 72, start: 1, duration: 0.5, velocity: 80)]
        XCTAssertEqual(snapshot.trackIDs, [.piano, .guitar, .bass, .drums, .lead, .vibes])
        let decoded = try JSONDecoder().decode(SongSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.trackIDs, snapshot.trackIDs)
        XCTAssertEqual(decoded.track(.vibes).notes.map(\.pitch), [72])   // (note ids aren't stored)
        XCTAssertEqual(snapshot.track(.lead).instrument, "Flute")
    }

    func testAddAndRemoveVersionKindsRoundTripAndHaveTitles() throws {
        for kind in [VersionKind.addTrack(.keys), .removeTrack(.keys)] {
            XCTAssertEqual(try JSONDecoder().decode(VersionKind.self, from: JSONEncoder().encode(kind)), kind)
        }
        XCTAssertEqual(VersionKind.addTrack(.keys).title, "Added Keys & Pads")
        XCTAssertEqual(VersionKind.removeTrack(.lead).title, "Removed Lead")
    }

    func testWireSongOnlyBuildsTheRequestedTracks() {
        let wire = WireSong(seed: 1, seconds: 10, tracks: ["piano": [], "lead": [Note(pitch: 70, start: 0, duration: 1, velocity: 80)]])
        let snapshot = wire.snapshot(style: .lofi, instruments: [:], tracks: [.piano, .lead])
        XCTAssertEqual(snapshot.trackIDs, [.piano, .lead])
        XCTAssertEqual(snapshot.track(.lead).notes.count, 1)
    }

    func testBusynessIsOptionalSoOldProjectsLoad() throws {
        var project = Project(name: "Old")
        project.versions = [Version(number: 1, createdAt: .now, kind: .newTake(seed: 1), changedTracks: [],
                                    snapshot: .empty(style: .lofi, length: 30))]
        project.currentVersionID = project.versions[0].id
        let data = try JSONEncoder().encode(project)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["busyness"], "an unset value isn't written")
        json.removeValue(forKey: "busyness")
        let decoded = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.songBusyness, Project.defaultBusyness)
        XCTAssertNil(decoded.currentSnapshot?.track(.piano).busyness)

        project.busyness = 0.3
        project.versions[0].snapshot.tracks[1].busyness = 0.8
        let again = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(again.busyness, 0.3)
        XCTAssertEqual(again.currentSnapshot?.track(.guitar).busyness, 0.8)
    }
}
