import SwiftUI

#if os(iOS)
/// The iPhone library (HANDOFF §5.1, artboard "iPhone library"): large title "Projects", sort and
/// filter menu at the leading edge, + at the trailing edge, a search field and a two-column grid.
/// Long press a card for Rename, Duplicate, Export…, Copy Seed, Delete. With no projects yet the
/// first-launch welcome takes its place.
struct PhoneLibraryView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(AppSession.self) private var session
    @Binding var exportOnOpen: Bool

    @State private var sort: LibraryGridView.Sort = .lastEdited
    @State private var showTrash = false
    @State private var query = ""
    @State private var renaming: Project?
    @State private var draftName = ""
    @State private var pendingPermanentDelete: Project?

    private var projects: [Project] {
        let base = showTrash ? store.trashed : store.active
        let filtered = query.isEmpty ? base : base.filter { $0.name.localizedCaseInsensitiveContains(query) }
        switch sort {
        case .lastEdited: return filtered.sorted { $0.modifiedAt > $1.modifiedAt }
        case .name: return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .created: return filtered.sorted { $0.createdAt > $1.createdAt }
        }
    }

    var body: some View {
        Group {
            if store.active.isEmpty && !showTrash {
                PhoneFirstLaunchView()
                    .toolbar(.hidden, for: .navigationBar)
            } else {
                grid
                    .navigationTitle(showTrash ? L("Recently Deleted") : L("Projects"))
                    .navigationBarTitleDisplayMode(.large)
                    .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                                prompt: "Search projects")
                    .toolbar { toolbar }
            }
        }
        .background(Color.lfbWindow)
        .alert("Rename Project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { if let p = renaming { store.rename(p, to: draftName) } }
        }
        .alert("Delete Permanently?", isPresented: Binding(get: { pendingPermanentDelete != nil },
                                                             set: { if !$0 { pendingPermanentDelete = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Permanently", role: .destructive) {
                if let p = pendingPermanentDelete { store.permanentlyDelete(p) }
            }
        } message: {
            Text("“\(pendingPermanentDelete?.name ?? "")” and all its versions will be deleted. This cannot be undone.")
        }
    }

    private var grid: some View {
        ScrollView {
            if projects.isEmpty {
                ContentUnavailableView(showTrash ? L("Nothing in Recently Deleted") : L("No Results"),
                                       systemImage: showTrash ? "trash" : "magnifyingglass",
                                       description: Text(showTrash ? L("Deleted projects stay here for 30 days.") : L("Try another name.")))
                    .padding(.top, 60)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(projects) { project in
                    Button { session.open(project) } label: { PhoneProjectCard(project: project) }
                        .buttonStyle(.plain)
                        .disabled(showTrash)
                        .contextMenu { menu(for: project) }
                        .accessibilityIdentifier("library-card")
                }
            }
            .padding(.horizontal, LFBSpace.lg)
            .padding(.bottom, LFBSpace.lg)
        }
        .background(Color.lfbWindow)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(LibraryGridView.Sort.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                Divider()
                Toggle(isOn: $showTrash) { Label("Recently Deleted", systemImage: "trash") }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
            }
            .accessibilityLabel("Sort and filter")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showTrash = false; session.newProject() } label: { Image(systemName: "plus") }
                .accessibilityLabel("New project")
                .accessibilityIdentifier("new-project")
        }
    }

    @ViewBuilder private func menu(for project: Project) -> some View {
        if showTrash {
            Button("Put Back", systemImage: "arrow.uturn.backward") { store.restoreFromTrash(project) }
            Button("Delete Permanently", systemImage: "trash", role: .destructive) { pendingPermanentDelete = project }
        } else {
            Button("Rename", systemImage: "pencil") { draftName = project.name; renaming = project }
            Button("Duplicate", systemImage: "plus.square.on.square") { store.duplicate(project) }
            Button("Export…", systemImage: "square.and.arrow.up") { exportOnOpen = true; session.open(project) }
                .disabled(!project.hasGenerated)
            Button("Copy Seed", systemImage: "doc.on.doc") {
                if let seed = project.current?.snapshot.seed { Pasteboard.copy(String(seed)) }
            }
            .disabled(!project.hasGenerated)
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { store.moveToTrash(project) }
        }
    }
}

/// A library card: 84 pt thumbnail of the lanes, then name and "style · length · last edited".
struct PhoneProjectCard: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PhoneThumbnail(snapshot: project.current?.snapshot, duration: max(project.lengthSeconds, 1))
                .padding(.vertical, 6).padding(.horizontal, 8)
                .frame(height: 84)
            .frame(maxWidth: .infinity)
            .background(Color.lfbWell)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1)
                Text(project.subtitle).font(.system(size: 12)).foregroundStyle(Color.lfbTextSecondary).lineLimit(1)
            }
            .padding(EdgeInsets(top: 9, leading: 12, bottom: 11, trailing: 12))
        }
        .background(Color.lfbSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.07), radius: 3, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

/// The card thumbnail (`.thumb`): one thin row per track, notes 3 pt high in the track color.
struct PhoneThumbnail: View {
    let snapshot: SongSnapshot?
    let duration: Double

    var body: some View {
        Canvas { ctx, size in
            guard let snapshot, !snapshot.tracks.isEmpty else { return }
            let rowH = size.height / CGFloat(snapshot.tracks.count)
            for (row, track) in snapshot.tracks.enumerated() {
                guard !track.notes.isEmpty else { continue }
                let lo = track.notes.map(\.pitch).min() ?? 0
                let span = Double(max((track.notes.map(\.pitch).max() ?? 0) - lo, 1))
                let top = CGFloat(row) * rowH + 2, usable = max(rowH - 7, 1)
                for n in track.notes {
                    let x = CGFloat(n.start / duration) * size.width
                    let w = max(CGFloat(n.duration / duration) * size.width, 2)
                    let y = top + CGFloat(1 - Double(n.pitch - lo) / span) * usable
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: 3), cornerRadius: 1.5),
                             with: .color(track.id.color))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// First launch (HANDOFF §5.1, artboard "iPhone · first launch"): mark, title, one sentence,
/// the two style cards full width, length, Generate and the generator status. Generate creates
/// the first project, starts the take and pushes the project screen.
struct PhoneFirstLaunchView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(AppSession.self) private var session
    @State private var style: MusicStyle = .lofi
    @State private var length: Double = 90

    private var status: GeneratorStatus { session.generator.currentStatus }

    var body: some View {
        GeometryReader { geo in
        ScrollView {
            VStack(spacing: LFBSpace.lg) {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(zip(TrackID.core, [30.0, 44, 22, 36])), id: \.0) { id, h in
                        RoundedRectangle(cornerRadius: 3).fill(id.color).frame(width: 10, height: h)
                    }
                }
                .frame(height: 48)
                .accessibilityHidden(true)
                Text("Make your first track").font(.system(size: 28, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text("Pick a feel. Lo-Fi & Bossa writes a short four-part song that you can mix, rework and export.")
                    .font(.system(size: 14)).foregroundStyle(Color.lfbTextSecondary)
                    .multilineTextAlignment(.center)
                VStack(spacing: LFBSpace.sm) {
                    ForEach(MusicStyle.allCases) { s in styleCard(s) }
                }
                HStack(spacing: LFBSpace.md) {
                    Text("Length").font(.system(size: 13)).foregroundStyle(Color.lfbTextSecondary)
                    Slider(value: $length, in: 15...180, step: 15).accessibilityLabel("Length")
                    Text(formatTimecode(length)).font(.system(size: 15)).monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                Button(action: start) { Label("Generate", systemImage: "sparkles") }
                    .buttonStyle(PhoneBigButtonStyle())
                    .accessibilityIdentifier("first-generate")
                statusLine
            }
            .padding(.horizontal, 20)
            .padding(.vertical, LFBSpace.xl)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, minHeight: geo.size.height)
        }
        .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color.lfbWindow)
    }

    private func styleCard(_ s: MusicStyle) -> some View {
        Button { style = s } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(s.title).font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(s == .lofi
                     ? L("Electric piano, soft guitar, round bass and a dusty kit, with tape warmth and a little vinyl.")
                     : L("Nylon guitar, grand piano, upright bass and light percussion, with an open, airy room."))
                    .font(.system(size: 13)).foregroundStyle(Color.lfbTextSecondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(style == s ? Color.lfbAccentWash : Color.lfbSurface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style == s ? Color.lfbAccent : Color.lfbControlHairline, lineWidth: style == s ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(style == s ? .isSelected : [])
    }

    @ViewBuilder private var statusLine: some View {
        HStack(spacing: 6) {
            switch status {
            case .ready:
                Circle().fill(Color.lfbReady).frame(width: 7, height: 7)
                Text("Generator ready · usually under a minute")
            case .starting:
                ProgressView().controlSize(.mini)
                Text("Loading the music model…")
            case .offline:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.lfbCaution)
                Text("The generator isn't running. You can still start an empty project.")
            }
        }
        .font(.system(size: 13)).foregroundStyle(Color.lfbTextSecondary)
        .multilineTextAlignment(.center)
        .frame(minHeight: 30)
        .accessibilityElement(children: .combine)
    }

    private func start() {
        var project = store.create(style: style)
        project.lengthSeconds = length
        store.update(project)
        session.open(project)
        if case .ready = status { session.activeModel?.generate() }
    }
}
#endif
