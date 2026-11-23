import XCTest
@testable import LofiBossa

/// The stage's timeline zoom: one time→x mapping for the ruler, lanes, selections and playhead.
final class TimelineWindowTests: XCTestCase {
    func testWholeSongFitsAtZoomOne() {
        let w = TimelineWindow()
        XCTAssertEqual(w.x(for: 30, width: 600, duration: 60), 300)
        XCTAssertEqual(w.time(atX: 600, width: 600, duration: 60), 60)
        XCTAssertFalse(w.isZoomed)
    }

    func testZoomKeepsTheAnchorInPlace() {
        var w = TimelineWindow()
        w.setZoom(4, anchor: 30, duration: 60)          // 15 s visible
        XCTAssertEqual(w.visibleSeconds(duration: 60), 15)
        XCTAssertEqual(w.x(for: 30, width: 600, duration: 60), 300, accuracy: 0.001, "30 s stays mid-lane")
        XCTAssertEqual(w.time(atX: w.x(for: 41, width: 600, duration: 60), width: 600, duration: 60), 41, accuracy: 1e-9)
    }

    func testZoomAndScrollStayInsideTheSong() {
        var w = TimelineWindow()
        w.setZoom(100, duration: 60)
        XCTAssertEqual(w.zoom, TimelineWindow.maxZoom(duration: 60))
        w.scroll(by: 1000, duration: 60)
        XCTAssertEqual(w.end(duration: 60), 60, accuracy: 1e-9)
        w.scroll(by: -1000, duration: 60)
        XCTAssertEqual(w.start, 0)
        w.setZoom(0.2, duration: 60)
        XCTAssertEqual(w, TimelineWindow())
    }

    func testFollowingThePlayheadPagesAlong() {
        var w = TimelineWindow()
        w.setZoom(4, anchor: 0, duration: 60)
        w.follow(20, duration: 60)
        XCTAssertLessThanOrEqual(w.start, 20)
        XCTAssertGreaterThan(w.end(duration: 60), 20)
    }

    func testLabelStepKeepsLabelsApart() {
        XCTAssertEqual(TimelineRuler.labelStep(visibleSeconds: 60, width: 900, minSpacing: 96), 10)
        XCTAssertEqual(TimelineRuler.labelStep(visibleSeconds: 6, width: 900, minSpacing: 96), 1)
    }

    @MainActor
    func testTheModelZoomsAroundThePlayheadAndFitResets() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lfb-zoom-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ProjectStore(root: folder)
        var project = store.create(style: .bossa)
        project.lengthSeconds = 60
        store.update(project)
        let model = ProjectViewModel(project: project, store: store, generator: FakeGeneratorClient())
        defer { model.teardown() }
        model.generate()
        for _ in 0..<400 where model.project.versions.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.canZoomTimelineOut)

        model.seek(to: 40)
        model.zoomTimelineIn(); model.zoomTimelineIn()
        XCTAssertTrue(model.timeline.isZoomed)
        XCTAssertTrue(model.timeline.start <= 40 && model.timeline.end(duration: model.duration) >= 40,
                      "the playhead stays in view")
        model.scrollTimeline(by: -100)
        XCTAssertEqual(model.timeline.start, 0)
        model.zoomTimelineToFit()
        XCTAssertFalse(model.timeline.isZoomed)
    }
}
