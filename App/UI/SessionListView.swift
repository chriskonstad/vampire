import SwiftUI
import PhotosUI

import VampireIndex

/// Home screen: resume an existing culling session or start a new one from a
/// system photo picker selection. Nothing is indexed from here — work only
/// happens inside an open session.
struct SessionListView: View {
    @Environment(AppModel.self) private var model
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showsPicker = false

    // New-session naming: picker selection is parked here until named.
    @State private var pendingAssetIDs: [String]?
    @State private var draftName = ""

    // Rename flow.
    @State private var renameTarget: SessionSummary?
    @State private var renameText = ""


    var body: some View {
        NavigationStack {
            Group {
                if model.sessionSummaries.isEmpty {
                    ContentUnavailableView {
                        Label("No sessions", systemImage: "tray")
                    } description: {
                        Text("Pick the photos from a shoot to start culling. Only what you select gets indexed.")
                    } actions: {
                        newSessionButton
                    }
                } else {
                    sessionList
                }
            }
            .navigationTitle("Vampire")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Wireless field culling: today's camera session, same
                    // culling screen as library sessions.
                    Button { model.openCameraSession() } label: {
                        Label("Camera", systemImage: "camera.badge.ellipsis")
                    }
                }
                if !model.sessionSummaries.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { newSessionButton }
                }
            }
            .photosPicker(
                isPresented: $showsPicker,
                selection: $pickerItems,
                matching: .images,
                photoLibrary: .shared() // .shared() is what makes itemIdentifier non-nil
            )
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                let ids = items.compactMap(\.itemIdentifier)
                pickerItems = []
                guard !ids.isEmpty else { return }
                draftName = Self.defaultName()
                pendingAssetIDs = ids
            }
            .alert("Name this session", isPresented: Binding(
                get: { pendingAssetIDs != nil },
                set: { if !$0 { pendingAssetIDs = nil } }
            )) {
                TextField("Session name", text: $draftName)
                Button("Start Culling") {
                    if let ids = pendingAssetIDs {
                        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                        model.createSession(name: name.isEmpty ? Self.defaultName() : name, assetIDs: ids)
                    }
                    pendingAssetIDs = nil
                }
                Button("Cancel", role: .cancel) { pendingAssetIDs = nil }
            } message: {
                Text("\(pendingAssetIDs?.count ?? 0) photos selected")
            }
            .alert("Rename session", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("Session name", text: $renameText)
                Button("Rename") {
                    if let target = renameTarget {
                        model.renameSession(id: target.id, to: renameText)
                    }
                    renameTarget = nil
                }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            }
            .fullScreenCover(isPresented: Binding(
                get: { model.currentSession != nil },
                set: { if !$0 { model.closeSession() } }
            )) {
                SessionView()
            }
        }
        .onAppear {
            model.refreshSessionList()
            #if DEBUG
            // Screenshot/demo hook: `-demo.openCamera YES` opens the camera
            // session straight away (pair with tools/fake_a7rv.py).
            if UserDefaults.standard.bool(forKey: "demo.openCamera") { model.openCameraSession() }
            #endif
        }
    }

    private var newSessionButton: some View {
        Button {
            showsPicker = true
        } label: {
            Label("New Session", systemImage: "plus")
        }
    }

    private var sessionList: some View {
        List {
            ForEach(model.sessionSummaries) { summary in
                Button {
                    model.openSession(summary.record)
                } label: {
                    SessionRow(summary: summary)
                }
                .foregroundStyle(.primary)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        model.deleteSession(summary)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        beginRename(summary)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                }
                .contextMenu {
                    Button {
                        beginRename(summary)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        model.deleteSession(summary)
                    } label: {
                        Label("Delete Session", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func beginRename(_ summary: SessionSummary) {
        renameText = summary.record.name
        renameTarget = summary
    }

    static func defaultName(date: Date = Date()) -> String {
        "Session \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct SessionRow: View {
    let summary: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if summary.record.kind == .camera {
                    Image(systemName: "camera.fill").foregroundStyle(.secondary)
                }
                Text(summary.record.name)
                    .font(.headline)
                Spacer()
                if let opened = summary.record.lastOpenedAt {
                    Text(opened.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                Text("\(summary.assetCount) photos")
                if summary.decidedCount > 0 {
                    Label("\(summary.keepCount)", systemImage: "heart.fill")
                        .foregroundStyle(.green)
                    Label("\(summary.rejectCount)", systemImage: "xmark.bin.fill")
                        .foregroundStyle(.red)
                    Text("\(summary.decidedCount)/\(summary.assetCount) decided")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }
}
