import SwiftUI
import Accessibility

/// Makes the notes of a piano roll visible to VoiceOver and Switch Control. The roll itself is a
/// Canvas, which assistive technologies see as one picture; this invisible layer sits on top of it
/// (same coordinates) with one element per note, a "Notes" rotor to step through them, and custom
/// actions that reuse the pure edits in `NoteEditing`. It never takes touches or clicks.
struct NoteAccessibilityLayer: View {
    let notes: [Note]
    let grid: BeatGrid?
    let songLength: Double
    /// Seconds a note grows or shrinks by with "Longer" / "Shorter".
    let lengthStep: Double
    /// Where a note is drawn, in this layer's coordinates.
    let frame: (Note) -> CGRect
    let select: (Note.ID) -> Void
    /// Replaces the track's notes (an undoable edit).
    let commit: ([Note]) -> Void
    let audition: (Note) -> Void

    @Namespace private var rotorSpace

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(notes) { note in
                let r = frame(note)
                Color.clear
                    .frame(width: max(r.width, 1), height: max(r.height, 1))
                    .offset(x: r.minX, y: r.minY)
                    .accessibilityElement()
                    .accessibilityLabel(NoteDescription.text(note, grid: grid))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Swipe up or down to change the pitch. More actions are in the actions rotor.")
                    .accessibilityRotorEntry(id: note.id, in: rotorSpace)
                    .accessibilityAdjustableAction { direction in
                        edit(note, semitones: direction == .increment ? 1 : -1)
                    }
                    .accessibilityAction { select(note.id); audition(note) }
                    .accessibilityAction(named: "Up one semitone") { edit(note, semitones: 1) }
                    .accessibilityAction(named: "Down one semitone") { edit(note, semitones: -1) }
                    .accessibilityAction(named: "Up one octave") { edit(note, semitones: 12) }
                    .accessibilityAction(named: "Down one octave") { edit(note, semitones: -12) }
                    .accessibilityAction(named: "Longer") { resize(note, by: lengthStep) }
                    .accessibilityAction(named: "Shorter") { resize(note, by: -lengthStep) }
                    .accessibilityAction(named: "Delete") { commit(NoteEditing.removing(notes, id: note.id)) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityRotor("Notes") {
            ForEach(notes) { note in
                AccessibilityRotorEntry(Text(NoteDescription.text(note, grid: grid)), id: note.id, in: rotorSpace)
            }
        }
        .allowsHitTesting(false)
    }

    private func edit(_ note: Note, semitones: Int) {
        let updated = NoteEditing.transposing(notes, id: note.id, by: semitones)
        commit(updated)
        select(note.id)
        if let n = updated.first(where: { $0.id == note.id }) { audition(n) }
    }

    private func resize(_ note: Note, by delta: Double) {
        commit(NoteEditing.resizing(notes, id: note.id, by: delta, songLength: songLength))
        select(note.id)
    }
}

// MARK: - Audio Graphs

extension AXChartDescriptor {
    /// Pitch over time for one part, for VoiceOver's Audio Graphs (hear the melodic contour).
    static func contour(title: String, notes: [Note], duration: Double) -> AXChartDescriptor {
        let sorted = notes.sorted { $0.start < $1.start }
        let lo = Double(sorted.map(\.pitch).min() ?? 48), hi = Double(sorted.map(\.pitch).max() ?? 72)
        let xAxis = AXNumericDataAxisDescriptor(title: "Time", range: 0...max(duration, 1), gridlinePositions: []) {
            formatTimecode($0)
        }
        let yAxis = AXNumericDataAxisDescriptor(title: "Pitch", range: lo...max(hi, lo + 1), gridlinePositions: []) {
            NoteDescription.pitchName(Int($0.rounded()))
        }
        let points = sorted.map { AXDataPoint(x: $0.start, y: Double($0.pitch)) }
        let series = AXDataSeriesDescriptor(name: title, isContinuous: false, dataPoints: points)
        return AXChartDescriptor(title: "\(title) melodic contour", summary: "\(sorted.count) notes",
                                 xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: [series])
    }
}

/// `accessibilityChartDescriptor` wants a representable; this one wraps a closure.
struct NoteContourDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let notes: [Note]
    let duration: Double
    func makeChartDescriptor() -> AXChartDescriptor { .contour(title: title, notes: notes, duration: duration) }
    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        let fresh = AXChartDescriptor.contour(title: title, notes: notes, duration: duration)
        descriptor.title = fresh.title; descriptor.summary = fresh.summary
        descriptor.xAxis = fresh.xAxis; descriptor.yAxis = fresh.yAxis; descriptor.series = fresh.series
    }
}
