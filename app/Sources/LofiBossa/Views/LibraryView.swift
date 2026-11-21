import SwiftUI

enum SidebarSelection: Hashable {
    case allProjects
    case recentlyDeleted
    case project(Project.ID)
}

/// Sidebar: All Projects (with count), Recently Deleted, a "Recent" list of six, and
/// New Project pinned to the bottom.
struct SidebarView: View {
    @Environment(ProjectStore.self) private var store
    @Binding var selection: SidebarSelection

    var body: some View {
        List(selection: listSelection) {
            Section {
                Label("All Projects", systemImage: "square.grid.2x2")
                    .badge(store.active.count)
                    .tag(SidebarSelection.allProjects)
                Label("Recently Deleted", systemImage: "trash")
                    .badge(store.trashed.isEmpty ? 0 : store.trashed.count)
                    .tag(SidebarSelection.recentlyDeleted)
            }
            if !store.recent.isEmpty {
                Section("Recent") {
                    ForEach(store.recent) { project in
                        Label(project.name, systemImage: "music.note")
                            .lineLimit(1)
                            .tag(SidebarSelection.project(project.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                let p = store.create()
                selection = .project(p.id)
            } label: {
                Label("New Project", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(LFBSpace.sm)
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: LFBSize.sidebarWidth, max: 280)
    }
    /// iOS lists only take an optional selection; the Mac keeps its non-optional one.
    #if os(macOS)
    private var listSelection: Binding<SidebarSelection> { $selection }
    #else
    private var listSelection: Binding<SidebarSelection?> {
        Binding(get: { selection }, set: { if let value = $0 { selection = value } })
    }
    #endif
}

/// Project library grid, and the same component filtered to Recently Deleted.
struct LibraryGridView: View {
    @Environment(ProjectStore.self) private var store
    let isTrash: Bool
    var status: GeneratorStatus = .starting
    var onOpen: (Project) -> Void

    enum Sort: String, CaseIterable, Identifiable {
        case lastEdited = "Last Edited", name = "Name", created = "Created"
        var id: String { rawValue }
    }

    @State private var sort: Sort = .lastEdited
    @State private var query = ""
    @State private var renamingID: Project.ID?
    @State private var pendingPermanentDelete: Project?

    private var projects: [Project] {
        let base = isTrash ? store.trashed : store.active
        let filtered = query.isEmpty ? base : base.filter { $0.name.localizedCaseInsensitiveContains(query) }
        switch sort {
        case .lastEdited: return filtered.sorted { $0.modifiedAt > $1.modifiedAt }
        case .name: return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .created: return filtered.sorted { $0.createdAt > $1.createdAt }
        }
    }

    var body: some View {
        Group {
            if !isTrash && store.active.isEmpty {
                FirstLaunchView(status: status, onCreated: onOpen)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: LFBSpace.lg)], spacing: LFBSpace.lg) {
                        ForEach(projects) { project in
                            ProjectCard(project: project, isTrash: isTrash, isRenaming: renamingID == project.id,
                                       onOpen: { onOpen(project) },
                                       onRename: { renamingID = project.id },
                                       onCommitRename: { name in store.rename(project, to: name); renamingID = nil },
                                       onDuplicate: { store.duplicate(project) },
                                       onCopySeed: { copySeed(of: project) },
                                       onDelete: { store.moveToTrash(project) },
                                       onRestore: { store.restoreFromTrash(project) },
                                       onPermanentlyDelete: { pendingPermanentDelete = project })
                        }
                    }
                    .padding(LFBSpace.xl)
                }
                .background(Color.lfbWindow)
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(isTrash ? "Recently Deleted" : "All Projects").font(.lfbTitle)
                    if !isTrash {
                        Text("\(store.active.count) projects · saved automatically on this \(LFBSize.isTouch ? "device" : "Mac")")
                            .font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
                    }
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if !isTrash {
                    Picker("Sort", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    Button {
                        let p = store.create()
                        onOpen(p)
                    } label: {
                        Label("New Project", systemImage: "plus")
                    }
                    .keyboardShortcut("n")
                }
            }
        }
        .alert("Delete Permanently?", isPresented: Binding(get: { pendingPermanentDelete != nil },
                                                             set: { if !$0 { pendingPermanentDelete = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Permanently", role: .destructive) {
                if let p = pendingPermanentDelete { store.permanentlyDelete(p) }
            }
        } message: {
            Text("\"\(pendingPermanentDelete?.name ?? "")\" and all its versions will be deleted. This cannot be undone.")
        }
    }

    private func copySeed(of project: Project) {
        guard let seed = project.current?.snapshot.seed else { return }
        Pasteboard.copy(String(seed))
    }
}

private struct ProjectCard: View {
    let project: Project
    let isTrash: Bool
    let isRenaming: Bool
    let onOpen: () -> Void
    let onRename: () -> Void
    let onCommitRename: (String) -> Void
    let onDuplicate: () -> Void
    let onCopySeed: () -> Void
    let onDelete: () -> Void
    let onRestore: () -> Void
    let onPermanentlyDelete: () -> Void

    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: LFBSpace.sm) {
            thumbnail
                .frame(height: LFBSize.libraryCardThumbHeight)
                .frame(maxWidth: .infinity)
                .background(Color.lfbWell, in: RoundedRectangle(cornerRadius: LFBRadius.card))
            if isRenaming {
                TextField("Name", text: $draftName, onCommit: { onCommitRename(draftName) })
                    .textFieldStyle(.plain).font(.lfbHeadline)
                    .focused($nameFieldFocused)
                    .onAppear { draftName = project.name; nameFieldFocused = true }
            } else {
                Text(project.name).font(.lfbHeadline).lineLimit(1)
            }
            Text(project.subtitle).font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary).lineLimit(1)
        }
        .padding(LFBSpace.md)
        .background(Color.lfbSurface, in: RoundedRectangle(cornerRadius: LFBRadius.card))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .contextMenu { contextMenuItems }
    }

    private var thumbnail: some View {
        HStack(spacing: 3) {
            ForEach(project.current?.snapshot.trackIDs ?? TrackID.core) { id in
                GeometryReader { geo in
                    NoteLaneView(notes: project.current?.snapshot.track(id).notes ?? [],
                                duration: max(project.lengthSeconds, 1), color: id.color)
                }
            }
        }
        .padding(LFBSpace.sm)
    }

    @ViewBuilder private var contextMenuItems: some View {
        if isTrash {
            Button("Put Back", action: onRestore)
            Divider()
            Button("Delete Permanently", role: .destructive, action: onPermanentlyDelete)
        } else {
            Button("Open") { onOpen() }
            Button("Rename") { onRename() }
            Button("Duplicate") { onDuplicate() }.keyboardShortcut("d")
            Divider()
            Button("Export…") { onOpen() }.keyboardShortcut("e")
            Button("Copy Seed") { onCopySeed() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }
}

/// No projects yet: a short welcome plus the same style/length/Generate controls as the
/// recipe bar, so the first song can be made without the grid existing yet.
struct FirstLaunchView: View {
    @Environment(ProjectStore.self) private var store
    var onCreated: (Project) -> Void = { _ in }

    @State private var style: MusicStyle = .lofi
    @State private var length: Double = 90
    let status: GeneratorStatus

    init(status: GeneratorStatus = .starting, onCreated: @escaping (Project) -> Void = { _ in }) {
        self.status = status
        self.onCreated = onCreated
    }

    var body: some View {
        VStack(spacing: LFBSpace.xl) {
            HStack(spacing: 3) {
                ForEach(TrackID.core) { id in
                    RoundedRectangle(cornerRadius: 2).fill(id.color).frame(width: 36, height: 10)
                }
            }
            VStack(spacing: LFBSpace.xs) {
                Text("Make your first track").font(.lfbLargeTitle)
                Text("Pick a style and length, and the generator writes piano, guitar, bass and drums.")
                    .font(.lfbBody).foregroundStyle(Color.lfbTextSecondary)
            }
            HStack(spacing: LFBSpace.md) {
                ForEach(MusicStyle.allCases) { s in
                    StyleCard(style: s, isSelected: style == s) { style = s }
                }
            }
            VStack(spacing: LFBSpace.xs) {
                HStack {
                    Text("Length").foregroundStyle(Color.lfbTextSecondary)
                    Spacer()
                    Text(formatTimecode(length)).monospacedDigit()
                }
                Slider(value: $length, in: 15...180, step: 15)
            }
            .frame(width: 280)
            Button {
                let p = store.create(style: style)
                var updated = p; updated.lengthSeconds = length
                store.update(updated)
                onCreated(updated)
            } label: {
                Label("Generate", systemImage: "sparkles").frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            GeneratorStatusPill(status: status)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.lfbWindow)
    }
}

private struct StyleCard: View {
    let style: MusicStyle
    let isSelected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(style.title).font(.lfbHeadline)
                HStack(spacing: 3) {
                    ForEach(TrackID.core) { id in
                        RoundedRectangle(cornerRadius: 1.5).fill(id.color).frame(width: 16, height: 6)
                    }
                }
            }
            .padding(LFBSpace.lg)
            .frame(width: 140)
            .background(isSelected ? Color.lfbAccentWash : Color.lfbSurface, in: RoundedRectangle(cornerRadius: LFBRadius.card))
            .overlay(RoundedRectangle(cornerRadius: LFBRadius.card)
                .strokeBorder(isSelected ? Color.lfbAccent : Color.lfbControlHairline, lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }
}
