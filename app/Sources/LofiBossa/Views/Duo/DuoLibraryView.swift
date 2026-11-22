#if os(iOS)
import SwiftUI

/// The library on the unfolded Duo (artboard `DuoLibrary.dc.html`): the project list on the
/// left page (large title, search, rows with a 4-lane thumbnail), a preview of the selected
/// project on the right page (large thumbnail, meta, Open, preview play, Duplicate, Export).
/// With no projects yet, the shared first-launch welcome fills the screen.
struct DuoLibraryView: View {
    var axis: FoldInfo.Axis = .vertical
    @Environment(AppSession.self) private var session
    @State private var query = ""
    @State private var selectedID: Project.ID?

    private var projects: [Project] {
        let base = session.store.active.sorted { $0.modifiedAt > $1.modifiedAt }
        return query.isEmpty ? base : base.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var selected: Project? {
        projects.first { $0.id == selectedID } ?? projects.first
    }

    var body: some View {
        if session.store.active.isEmpty {
            FirstLaunchView(status: session.generator.currentStatus, onCreated: session.open)
        } else {
            DuoPages(axis: axis) {
                list
            } second: {
                preview
            }
            .padding(.top, axis == .vertical ? 8 : 0)
        }
    }

    // MARK: Left page

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button(action: session.newProject) { Image(systemName: "plus") }
                    .buttonStyle(DuoIconButtonStyle(solid: true))
                    .accessibilityLabel("New project")
            }
            .padding(.horizontal, 6).frame(height: LFBPhoneSize.navBar)
            Text("Projects").font(.system(size: 28, weight: .bold, design: .rounded))
                .padding(.horizontal, 16).padding(.bottom, 10)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.lfbTextTertiary)
                TextField("Search projects", text: $query).font(.system(size: 16))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            .padding(.horizontal, 12).frame(height: 40)
            .background(Color.lfbWell, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16).padding(.bottom, 14)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(projects) { project in
                        row(project)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private func row(_ project: Project) -> some View {
        let isOn = project.id == selected?.id
        return Button {
            selectedID = project.id
        } label: {
            HStack(spacing: 12) {
                DuoProjectThumbnail(project: project)
                    .frame(width: 96, height: 56)
                    .background(Color.lfbSurface, in: RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Color.lfbText)
                    Text(project.subtitle).font(.system(size: 12)).foregroundStyle(Color.lfbTextTertiary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(isOn ? Color.lfbAccentWash : .clear, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .contextMenu {
            Button("Open") { session.open(project) }
            Button("Duplicate") { selectedID = session.store.duplicate(project).id }
            Button("Copy Seed") { if let s = project.current?.snapshot.seed { Pasteboard.copy(String(s)) } }
            Divider()
            Button("Delete", role: .destructive) { session.store.moveToTrash(project) }
        }
    }

    // MARK: Right page

    @ViewBuilder private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let project = selected {
                DuoProjectThumbnail(project: project)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.lfbWell, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text(meta(project)).font(.system(size: 13)).foregroundStyle(Color.lfbTextSecondary).monospacedDigit()
                }
                HStack(spacing: 8) {
                    Button { session.open(project) } label: {
                        Text("Open").font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.lfbOnAccent)
                            .frame(maxWidth: .infinity, minHeight: LFBPhoneSize.bigButton)
                            .background(Color.lfbAccent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Button {
                        // Preview play opens the project and starts playing it: there is one audio
                        // engine per open project, and opening is instant.
                        session.open(project)
                        session.activeModel?.play()
                    } label: { Image(systemName: "play.fill") }
                        .buttonStyle(DuoIconButtonStyle(solid: true))
                        .disabled(project.current == nil)
                        .accessibilityLabel("Play preview")
                    Button { selectedID = session.store.duplicate(project).id } label: { Image(systemName: "plus.square.on.square") }
                        .buttonStyle(DuoIconButtonStyle(solid: true))
                        .accessibilityLabel("Duplicate")
                    Button {
                        session.open(project)
                        // The project page has to be on screen to hear the request.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(300))
                            NotificationCenter.default.post(name: .lfbExport, object: nil)
                        }
                    } label: { Image(systemName: "square.and.arrow.up") }
                        .buttonStyle(DuoIconButtonStyle(solid: true))
                        .disabled(project.current == nil)
                        .accessibilityLabel("Export")
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.lfbSurface, in: RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    }

    private func meta(_ p: Project) -> String {
        var parts = [p.style.title, formatTimecode(p.lengthSeconds)]
        if let seed = p.current?.snapshot.seed { parts.append("seed \(seed)") }
        parts.append(p.versions.count == 1 ? "1 version" : "\(p.versions.count) versions")
        parts.append("edited \(p.modifiedAt.formatted(.relative(presentation: .named)))")
        return parts.joined(separator: " · ")
    }
}

/// Four stacked lanes, one per track (`.thumb` / `.tl4`).
struct DuoProjectThumbnail: View {
    let project: Project

    var body: some View {
        VStack(spacing: 2) {
            ForEach(project.current?.snapshot.trackIDs ?? TrackID.core) { id in
                NoteLaneView(notes: project.current?.snapshot.track(id).notes ?? [],
                             duration: max(project.lengthSeconds, 1), color: id.color)
                    .allowsHitTesting(false)
            }
        }
        .padding(.vertical, 3)
    }
}
#endif
