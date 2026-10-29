import SwiftUI
import Photos
import PhotosUI

import CullIntent

/// An open culling session: grid of its photos (newest first), indexing
/// status, undo/redo, add-photos, Apply. Presented full-screen over the
/// session list; closing it stops all indexing work.
///
/// Camera sessions use the very same screen (grid, pager, HUD, bursts,
/// undo); they swap Add Photos for the camera link, and Apply for Import —
/// keepers come into Photos, rejects simply stay on the card.
struct SessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var pagerIndex: Int?
    @State private var applyError: String?
    @State private var confirmingApply = false
    @State private var applyResult: AppModel.ApplyResult?
    @State private var addItems: [PhotosPickerItem] = []
    @State private var showsAddPicker = false

    var body: some View {
        NavigationStack {
            Group {
                if model.isCameraSession && model.items.isEmpty {
                    CameraConnectPanel(camera: model.camera)
                } else {
                    GridView(pagerIndex: $pagerIndex, revision: model.verdictRevision,
                             imageRevision: model.imageRevision)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
                .navigationTitle(model.currentSession?.name ?? "Session")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .overlay(alignment: .bottom) { statusBar }
                .fullScreenCover(item: $pagerIndex) { index in
                    let target = pagerTarget(forFlatIndex: index)
                    PagerView(startGroup: target.group, startMemberID: target.memberID,
                              provider: model.imageProvider)
                }
        }
        .preferredColorScheme(.dark)
        .modifier(CameraPasswordPrompt(link: model.camera.link))
        #if DEBUG
        // Screenshot/demo hook: `-demo.pagerIndex N` opens the pager on the
        // Nth photo once the session has that many.
        .onChange(of: model.items.count) { _, count in
            let index = UserDefaults.standard.integer(forKey: "demo.pagerIndex") - 1
            if index >= 0, index < count, pagerIndex == nil, model.imageRevision > 0 {
                pagerIndex = index
                UserDefaults.standard.removeObject(forKey: "demo.pagerIndex")
            }
        }
        .onChange(of: model.imageRevision) { _, _ in
            let index = UserDefaults.standard.integer(forKey: "demo.pagerIndex") - 1
            if index >= 0, index < model.items.count, pagerIndex == nil, model.camera.cachedCount == model.items.count {
                pagerIndex = index
            }
        }
        #endif
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.isCameraSession { model.camera.resumeIfNeeded() }
        }
        .photosPicker(
            isPresented: $showsAddPicker,
            selection: $addItems,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: addItems) { _, items in
            guard !items.isEmpty else { return }
            let ids = items.compactMap(\.itemIdentifier)
            addItems = []
            model.addAssetsToCurrentSession(ids)
        }
        .alert("Apply session?", isPresented: $confirmingApply) {
            Button("Apply", role: .destructive) {
                Task { await runApply() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let counts = model.verdictCounts
            Text("^[\(counts[.reject, default: 0]) reject](inflect: true) → Recently Deleted. ^[\(counts[.keep, default: 0]) keeper](inflect: true) stay untouched in your library. One confirmation will follow.")
        }
        .alert("Apply failed", isPresented: .constant(applyError != nil)) {
            Button("OK") { applyError = nil }
        } message: {
            Text(applyError ?? "")
        }
        .sheet(item: $applyResult) { result in
            ApplySummaryView(result: result)
                .presentationDetents([.medium])
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                dismiss() // cover binding closes the session
            } label: {
                Label("Sessions", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
            }
        }

        ToolbarItemGroup(placement: .topBarLeading) {
            Button {
                model.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!model.canUndo)

            Button {
                model.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!model.canRedo)
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.isCameraSession {
                // Import = Apply for the card: keepers' full RAWs into
                // Photos. Nothing is deleted anywhere, so no confirmation.
                let pending = model.camera.pendingImports.count
                Button(pending > 0 ? "Import \(pending)" : "Import") { model.importKeepers() }
                    .bold()
                    .disabled(pending == 0 || model.camera.importProgress != nil)
            } else {
                Button {
                    showsAddPicker = true
                } label: {
                    Label("Add Photos", systemImage: "plus")
                }

                Button("Apply") { confirmingApply = true }
                    .bold()
                    .disabled(model.verdictCounts.isEmpty)
            }
        }
    }

    private var statusBar: some View {
        let counts = model.verdictCounts
        let progress = model.indexingProgress
        return VStack(spacing: 6) {
            if model.isCameraSession {
                CameraStatusRow(camera: model.camera, showsConnect: !model.items.isEmpty)
            }
            // Indexing progress: visible bar while the pass runs, gone when
            // done. Informational only — browsing is never gated on it.
            if progress.total > 0 && progress.done < progress.total {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.rays")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ProgressView(value: Double(progress.done), total: Double(progress.total))
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                    Text("\(progress.done)/\(progress.total)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
            HStack(spacing: 24) {
                Label("\(counts[.keep, default: 0])", systemImage: "heart.fill")
                    .foregroundStyle(.green)
                Label("\(counts[.reject, default: 0])", systemImage: "xmark.bin.fill")
                    .foregroundStyle(.red)
                Spacer()
            }
            .font(.title3.bold())
            .monospacedDigit()
        }
        .font(.footnote)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .animation(.default, value: progress.done < progress.total)
    }

    /// Grid taps carry a flat index; the pager navigates groups. A tap on a
    /// mid-burst frame lands on that exact frame inside its stack.
    private func pagerTarget(forFlatIndex index: Int) -> (group: Int, memberID: String?) {
        guard model.items.indices.contains(index) else { return (0, nil) }
        let assetID = model.items[index].id
        if let groupIndex = model.groupedItems.firstIndex(where: { group in
            group.contains { $0.id == assetID }
        }) {
            return (groupIndex, assetID)
        }
        return (0, nil)
    }

    private func runApply() async {
        do {
            applyResult = try await model.apply()
        } catch {
            applyError = "\(error)"
        }
    }
}

/// Post-Apply results: what was kept, what was deleted, and how much storage
/// the cull recovered.
struct ApplySummaryView: View {
    @Environment(\.dismiss) private var dismiss
    let result: AppModel.ApplyResult

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("\(result.sessionName) applied")
                .font(.title3.bold())

            Grid(horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Label("Kept", systemImage: "heart.fill")
                        .foregroundStyle(.green)
                        .gridColumnAlignment(.leading)
                    Text("\(result.keepCount)")
                        .bold()
                        .gridColumnAlignment(.trailing)
                    Text(result.keepBytes.map(Self.format) ?? "—")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                }
                GridRow {
                    Label("Deleted", systemImage: "xmark.bin.fill")
                        .foregroundStyle(.red)
                    Text("\(result.rejectCount)")
                        .bold()
                    Text(result.rejectBytes.map(Self.format) ?? "—")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.body)

            if let freed = result.rejectBytes, freed > 0 {
                Text("\(Self.format(freed)) frees up once Recently Deleted clears (30 days).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}
