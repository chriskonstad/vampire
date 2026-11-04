import SwiftUI

import BurstClustering
import CullIntent
import VampireIndex
import SonyMakerNotes

/// Full-screen culling pager with two axes:
/// - horizontal: swipe between positions (a single photo or a whole burst)
/// - vertical: swipe through the frames of a burst (photos shot <1s apart)
///
/// A burst is unmistakable: a "Burst k/m" chip over the photo and a dot rail
/// on the trailing edge showing where you are in the stack. Rating advances
/// through the burst first, then on to the next group. Tapping the active
/// rating clears the photo back to undecided and stays put.
///
/// Pages are pinch-zoomable (UIScrollView inside): at 1× the scroll view has
/// nothing to pan, so swipes page/scroll; zoomed in, drags pan the photo.
/// Reads previews + the index only (hard constraints 2 & 4).
struct PagerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Compact vertical = iPhone in landscape: chrome moves to side rails so
    /// the photo gets the full width.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.displayScale) private var displayScale

    /// Where we are — the one source of truth for the photo on screen.
    /// Order comes from `model.order`; the counter, burst indicator,
    /// ratings and preloading all derive from this.
    @State private var position: PagerPosition
    /// A scroll for one burst stack, carried out by that stack's
    /// ScrollViewReader. Stacks have no position *binding* on purpose: any
    /// write to one teleported the stack (screen recordings showed a
    /// one-frame jump, with or without withAnimation/ScrollPosition), and
    /// an animated scrollTo lost to it (the stack snapped back). Stacks
    /// report what they show instead (`PagerPosition.reportShown`).
    @State private var burstScroll: BurstScroll?

    /// Bursts re-ranked off screen (a new best frame moved to the top):
    /// each scrolls back to its top, so entering it starts at the best
    /// frame instead of wherever its scroll view had been left.
    @State private var topResets: [String: UUID] = [:]

    private struct BurstScroll: Equatable {
        let stackID: String
        let photoID: String
        let animated: Bool
        let token = UUID()
    }
    /// Created in init, never in onAppear: pages built before the loader
    /// existed captured `nil` and — paged TabView content isn't rebuilt —
    /// never observed it, so frames sat on the spinner until any tap.
    @State private var loader: PagerImageLoader?
    @State private var showsAFOverlay = true
    @State private var showsCompletion = false
    /// While zoomed into a photo, all paging is off: drags pan the photo
    /// (Photos behavior).
    @State private var isZoomedIn = false
    /// Changes when the pager's container resizes; rebuilds the paged
    /// TabView so it can't keep a stale page offset.
    @State private var viewportKey = ""

    /// Opens on a photo — a grid tap lands mid-burst on the exact frame.
    init(startPhotoID: String?, order: CullOrder, provider: CullImageProvider) {
        _loader = State(initialValue: PagerImageLoader(provider: provider))
        // Must be State initial values: paged TabView ignores a selection
        // assigned in onAppear.
        _position = State(initialValue: PagerPosition(photoID: startPhotoID, in: order))
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if verticalSizeClass == .compact {
                    landscapeLayout
                } else if geometry.size.width >= Self.expandedMinWidth {
                    expandedLayout
                } else {
                    portraitLayout
                }
            }
            .onAppear { viewportChanged(geometry.size) }
            .onChange(of: geometry.size) { _, size in viewportChanged(size) }
        }
        .background(.black)
        .overlay {
            if showsCompletion {
                completionCard
            }
        }
        .onAppear {
            focusLoader()
        }
        .onDisappear { model.pagerAnchorID = nil }
        .onChange(of: currentAsset?.id) { _, _ in
            focusLoader()
        }
        .onChange(of: model.order) { old, new in
            // New shots, re-clustering or a re-sort: stay on the same photo;
            // bursts re-ranked off screen go back to their (new) top.
            for stackID in position.reconcile(from: old, to: new) { topResets[stackID] = UUID() }
        }
        .onChange(of: model.imageRevision) { _, _ in
            // Camera frames landed in the cache: upgrade stand-ins in view.
            focusLoader()
        }
    }

    /// Done = every photo in the session is kept or rejected — not "reached
    /// the last photo". Rating past the end with photos still undecided
    /// wraps to the next undecided one instead.
    private var completionCard: some View {
        let counts = model.verdictCounts
        return VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("All photos decided")
                .font(.title3.bold())
            Text("^[\(counts[.keep, default: 0]) keep](inflect: true), ^[\(counts[.reject, default: 0]) reject](inflect: true). \(model.isCameraSession ? "Import your keepers" : "Apply") from the grid when you're ready.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Keep Culling") { showsCompletion = false }
                    .buttonStyle(.bordered)
                Button("Back to Grid") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(32)
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Layouts

    private var portraitLayout: some View {
        VStack(spacing: 0) {
            header
            // Faces above the photo (quality-ranked crops for the current frame).
            FaceStripView(assetID: currentAsset?.id)
                .frame(height: 64)
            // The HUD: every extracted signal, as skimmable chips.
            SignalStripView(record: currentAsset.flatMap { model.index[$0.id] })
            pager
            positionBar
            ratingBar
        }
    }

    /// Big portrait canvases — iPhone Duo unfolded (669pt wide) and up. Keyed
    /// to available width, not to a device (Apple's guidance for the fold:
    /// one adaptive layout), so it also applies to any future wide screen.
    static var expandedMinWidth: CGFloat {
        #if DEBUG
        // `-demo.expandedMinWidth 400` previews the expanded layout on
        // simulators without the iPhone Duo's screen.
        let override = UserDefaults.standard.double(forKey: "demo.expandedMinWidth")
        if override > 0 { return override }
        #endif
        return 600
    }

    /// Expanded (iPhone Duo unfolded): the photo gets as much of the canvas
    /// as possible. Information keeps its familiar place — faces and signals
    /// above the photo, the burst filmstrip below — and the decision buttons
    /// move to a narrow rail on the right, under the thumb (as in landscape),
    /// which frees the bottom bar's height for the photo.
    private var expandedLayout: some View {
        // Every row of chrome above or below the photo costs it height (the
        // binding dimension for landscape photos when unfolded in
        // landscape), so: no header row — its controls top the rail — and
        // faces share one row with the signal chips.
        HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        FaceStripView(assetID: currentAsset?.id, cropSize: 56)
                            .fixedSize(horizontal: true, vertical: false)
                        SignalStripView(record: currentAsset.flatMap { model.index[$0.id] })
                    }
                    .frame(height: 76)
                    pager
                    if currentStackItems.count > 1 {
                        BurstFilmstrip(
                            items: currentStackItems,
                            currentID: currentAsset?.id,
                            bestID: bestMemberID(in: currentStackItems),
                            revision: model.verdictRevision,
                            onSelect: { go(to: $0) }
                        )
                        .frame(height: 76)
                        .padding(.top, 6)
                    }
                    positionBar
                }
                VStack(spacing: 10) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down").frame(width: 44, height: 36)
                    }
                    counterView
                    Button { showsAFOverlay.toggle() } label: {
                        Image(systemName: showsAFOverlay ? "viewfinder" : "viewfinder.trianglebadge.exclamationmark")
                            .frame(width: 44, height: 36)
                    }
                    tallyView
                    rightRail
                }
                .foregroundStyle(.white)
                .frame(width: 84)
                .padding(.vertical, 8)
        }
    }

    private var tallyView: some View {
        let counts = model.verdictCounts
        let decided = counts[.keep, default: 0] + counts[.reject, default: 0]
        return VStack(spacing: 3) {
            Label("\(counts[.keep, default: 0])", systemImage: "heart.fill").foregroundStyle(.green)
            Label("\(counts[.reject, default: 0])", systemImage: "xmark").foregroundStyle(.red)
            Text("\(model.items.count - decided) left").foregroundStyle(.secondary)
        }
        .font(.caption.bold())
        .monospacedDigit()
    }

    /// Landscape: photo full-width in the middle, navigation/info rail on the
    /// left, rating rail under the right thumb. Signals overlay the photo.
    private var landscapeLayout: some View {
        HStack(spacing: 0) {
            leftRail
                .frame(width: 76)
            ZStack(alignment: .top) {
                pager
                SignalStripView(record: currentAsset.flatMap { model.index[$0.id] })
                    .padding(.top, 2)
            }
            .overlay(alignment: .bottom) { positionBar }
            rightRail
                .frame(width: 84)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var leftRail: some View {
        VStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 44, height: 36)
            }
            counterView
            FaceStripView(assetID: currentAsset?.id, axis: .vertical)
            Spacer(minLength: 0)
            Button {
                showsAFOverlay.toggle()
            } label: {
                Image(systemName: showsAFOverlay ? "viewfinder" : "viewfinder.trianglebadge.exclamationmark")
                    .frame(width: 44, height: 36)
            }
        }
        .padding(.vertical, 8)
        .foregroundStyle(.white)
    }

    private var rightRail: some View {
        let _ = model.verdictRevision
        return VStack(spacing: 14) {
            undoButton(compact: true)
            Divider().frame(width: 28)
            Spacer(minLength: 0)
            Group {
                rejectBurstButton(compact: true)
                crownButton(compact: true)
            }
            .opacity(currentStackItems.count > 1 ? 1 : 0)
            .disabled(currentStackItems.count <= 1)
            ratingButton(.reject, icon: "xmark", color: .red, compact: true)
            ratingButton(.keep, icon: "heart.fill", color: .green, compact: true)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
    }

    private var counterView: some View {
        // The camera line is always laid out (blank when unknown) so the
        // header height never changes while paging between photos.
        let camera = currentAsset
            .flatMap { model.index[$0.id]?.cameraModel }
        return VStack(spacing: 2) {
            Text("\(currentStackIndex + 1) / \(model.order.stacks.count)")
                .font(.caption.bold())
                .monospacedDigit()
            Text(camera ?? " ")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - Current position

    private var currentStackIndex: Int { model.order.stackIndex(ofStack: position.stackID) ?? 0 }

    private var currentStack: CullStack? {
        model.order.stackIndex(ofStack: position.stackID).map { model.order.stacks[$0] }
    }

    private var currentStackItems: [CullItem] {
        currentStack?.memberIDs.compactMap(model.item(withID:)) ?? []
    }

    private var currentAsset: CullItem? {
        position.currentPhotoID(in: model.order).flatMap(model.item(withID:))
    }

    /// Moves to a photo: scrolls its burst (animated) when it's in the
    /// current stack, else pages over and lands the stack on it.
    private func go(to photoID: String) {
        let order = model.order
        let withinStack = order.stack(containing: photoID)?.id == position.stackID
        if withinStack {
            position.move(to: photoID, in: order)
        } else {
            withAnimation { position.move(to: photoID, in: order) }
        }
        if let stackID = order.stack(containing: photoID)?.id, position.pendingPhotoID(inStack: stackID) != nil {
            burstScroll = BurstScroll(stackID: stackID, photoID: photoID, animated: withinStack)
            Task {
                // A move that never lands (the stack couldn't scroll yet)
                // gives way to what's really on screen.
                try? await Task.sleep(for: .seconds(PagerPosition.pendingLifetime + 0.1))
                position.expirePending()
            }
        }
    }

    /// Folding/unfolding (iPhone Duo) or rotating changes the viewport:
    /// size previews to it, and re-focus so frames in view upgrade.
    private func viewportChanged(_ size: CGSize) {
        viewportKey = "\(Int(size.width))x\(Int(size.height))"
        loader?.updateViewport(size, scale: displayScale)
        focusLoader()
    }

    private func focusLoader() {
        guard let asset = currentAsset else { return }
        model.pagerAnchorID = asset.id
        // Display order: inside a best-first burst the neighbors you'll
        // swipe to are the stack's, not the clock's.
        let items = model.orderedItems
        guard let index = items.firstIndex(where: { $0.id == asset.id }) else { return }
        loader?.focus(on: index, in: items)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
            }
            Spacer()
            counterView
            Spacer()
            Button {
                showsAFOverlay.toggle()
            } label: {
                Image(systemName: showsAFOverlay ? "viewfinder" : "viewfinder.trianglebadge.exclamationmark")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
    }

    // MARK: - Pager

    private var pager: some View {
        // Pages are keyed by stack ID, not index: re-clustering or new shots
        // can't slide you onto a different photo.
        TabView(selection: Binding(get: { position.stackID }, set: { position.pageChanged(to: $0) })) {
            ForEach(model.order.stacks, id: \.id) { stack in
                stackPage(stack)
                    .tag(stack.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .scrollDisabled(isZoomedIn)
        // A paged TabView keeps its old scroll offset when its container
        // resizes (rotation, iPhone Duo fold/unfold), leaving the page
        // shifted sideways — the photo looked cropped. Rebuild it per
        // viewport size; the selection binding restores the position.
        .id(viewportKey)
    }

    @ViewBuilder
    private func stackPage(_ stack: CullStack) -> some View {
        let members = stack.memberIDs.compactMap(model.item(withID:))
        if members.count == 1 {
            frame(for: members[0])
        } else if members.count > 1 {
            burstStack(stack, members: members)
        }
    }

    /// A burst: vertically paged stack of its frames + the chip and dot rail
    /// that make burst membership obvious.
    ///
    /// Frames size via containerRelativeFrame so each page is EXACTLY the
    /// paging stride — sizing them from a GeometryReader drifted from the
    /// scroll container under landscape safe-area insets, leaving a sliver
    /// of the next frame visible at the bottom ("tiled" photos).
    private func burstStack(_ stack: CullStack, members: [CullItem]) -> some View {
        let shownIndex = memberIndex(in: stack)
        let isCurrent = stack.id == position.stackID
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                // Non-lazy on purpose: programmatic scrolls (rating
                // auto-advance) animate smoothly only when the target frame
                // is already laid out.
                VStack(spacing: 0) {
                    ForEach(Array(members.enumerated()), id: \.element.id) { index, asset in
                        // Only frames you can reach soon watch the loader:
                        // with all 24 of a long burst redrawing on every
                        // image that landed, scrolling the stack stuttered.
                        let isNear = isCurrent ? abs(index - shownIndex) <= 4 : index == shownIndex
                        frame(for: asset, isNear: isNear)
                            .containerRelativeFrame([.horizontal, .vertical])
                            .id(asset.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            // The stack reports what it really shows; the indicator and the
            // ratings follow that.
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.6) { ids in
                if let id = ids.first { position.reportShown(id, inStack: stack.id) }
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(isZoomedIn)
            // Without this, the scroll view keeps a bottom safe-area content
            // inset in landscape (home indicator) and that band shows the top
            // of the NEXT frame — the "tiled photos" bug.
            .ignoresSafeArea(edges: .bottom)
            .onAppear {
                // Entering mid-burst (grid tap, undo, wrap-around): land
                // there — again after layout, in case it wasn't ready.
                guard let target = position.pendingPhotoID(inStack: stack.id) else { return }
                proxy.scrollTo(target, anchor: .top)
                Task {
                    try? await Task.sleep(for: .milliseconds(50))
                    if position.pendingPhotoID(inStack: stack.id) == target { proxy.scrollTo(target, anchor: .top) }
                }
            }
            .onChange(of: topResets[stack.id]) { _, reset in
                guard reset != nil, let top = stack.memberIDs.first else { return }
                proxy.scrollTo(top, anchor: .top)
            }
            .onChange(of: burstScroll) { _, move in
                guard let move, move.stackID == stack.id else { return }
                if move.animated {
                    // Quick, eased at both ends: one continuous glide.
                    withAnimation(.smooth(duration: 0.32)) { proxy.scrollTo(move.photoID, anchor: .top) }
                } else {
                    proxy.scrollTo(move.photoID, anchor: .top)
                }
            }
        }
        .overlay(alignment: .top) { burstChip(stack, members: members) }
        .overlay(alignment: .trailing) { burstDotRail(stack, members: members) }
    }

    /// Index of the frame a stack shows (or is moving to).
    private func memberIndex(in stack: CullStack) -> Int {
        position.photoID(inStack: stack.id, in: model.order)
            .flatMap { stack.memberIDs.firstIndex(of: $0) } ?? 0
    }

    private func burstChip(_ stack: CullStack, members: [CullItem]) -> some View {
        let index = memberIndex(in: stack)
        let isBest = stack.memberIDs[index] == bestMemberID(in: members)
        return HStack(spacing: 6) {
            Label(
                "Burst \(index + 1)/\(stack.memberIDs.count)",
                systemImage: "square.stack.3d.down.right.fill"
            )
            if isBest {
                Label("Best", systemImage: "star.fill")
                    .foregroundStyle(.black)
            }
        }
        .font(.caption.bold())
        .foregroundStyle(.black)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.yellow, in: Capsule())
        .padding(.top, 8)
        .allowsHitTesting(false)
    }

    private func burstDotRail(_ stack: CullStack, members: [CullItem]) -> some View {
        let shown = memberIndex(in: stack)
        let bestID = bestMemberID(in: members)
        return VStack(spacing: 5) {
            ForEach(stack.memberIDs.indices, id: \.self) { index in
                Group {
                    if stack.memberIDs[index] == bestID {
                        // The frame we think is best — a star from anywhere in
                        // the stack, and still a star (just bigger) while you're on it.
                        Image(systemName: "star.fill")
                            .font(.system(size: index == shown ? 14 : 8))
                            .foregroundStyle(.yellow)
                    } else {
                        Capsule()
                            .fill(index == shown ? Color.yellow : Color.white.opacity(0.35))
                            .frame(width: 4, height: index == shown ? 16 : 8)
                    }
                }
                // Fixed slots: the current one is tall, the rest short,
                // whatever's drawn in them — so the rail's height (and every
                // dot's position) never changes as you move through the burst.
                .frame(width: 14, height: index == shown ? 16 : 8)
            }
        }
        .padding(.trailing, 6)
        .animation(.snappy(duration: 0.2), value: shown)
        .allowsHitTesting(false)
    }

    private func frame(for asset: CullItem, isNear: Bool = true) -> some View {
        PagerFrameView(
            loader: isNear ? loader : nil,
            itemID: asset.id,
            record: model.index[asset.id],
            showsAFOverlay: showsAFOverlay,
            onZoomChange: { isZoomedIn = $0 }
        )
    }

    /// Horizontal position indicator: a scrubber-style track whose thumb
    /// tracks the current group, mirroring the vertical dot rail for bursts.
    @ViewBuilder
    private var positionBar: some View {
        let count = model.order.stacks.count
        let current = currentStackIndex
        if count > 1 {
            GeometryReader { geometry in
                let thumbWidth = max(geometry.size.width / CGFloat(count), 28)
                let travel = geometry.size.width - thumbWidth
                let progress = CGFloat(current) / CGFloat(count - 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule()
                        .fill(.white.opacity(0.65))
                        .frame(width: thumbWidth)
                        .offset(x: travel * progress)
                }
            }
            .frame(height: 4)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .animation(.snappy(duration: 0.2), value: current)
        }
    }

    // MARK: - Rating bar

    private var ratingBar: some View {
        let _ = model.verdictRevision
        // Undo lives on the LEFT: rating buttons stay under the right thumb.
        return HStack(spacing: 10) {
            undoButton(compact: false)

            Divider().frame(height: 24)

            ratingButton(.reject, icon: "xmark", color: .red)
            ratingButton(.keep, icon: "heart.fill", color: .green)

            // Burst shortcuts: keep the visible frame and reject its
            // siblings; reject the whole burst (bar any keepers). The slots
            // are always reserved so X/heart never shift between burst and
            // single photos.
            Group {
                crownButton(compact: false)
                rejectBurstButton(compact: false)
            }
            .opacity(currentStackItems.count > 1 ? 1 : 0)
            .disabled(currentStackItems.count <= 1)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
    }

    private func undoButton(compact: Bool) -> some View {
        Button {
            if let assetID = model.undo() {
                go(to: assetID)
            }
        } label: {
            // Same capsule language as the rating buttons.
            Image(systemName: "arrow.uturn.backward")
                .font(.title2.bold())
                .foregroundStyle(model.canUndo ? .white : .gray)
                .frame(width: compact ? 56 : 60, height: 48)
                .background(.white.opacity(model.canUndo ? 0.15 : 0.07), in: Capsule())
        }
        .disabled(!model.canUndo)
    }

    private func rejectBurstButton(compact: Bool) -> some View {
        let keepsSome = currentStackItems.contains { model.verdict(for: $0) == .keep }
        return Button {
            rejectBurst()
        } label: {
            Image(systemName: "square.stack.3d.down.right.fill")
                .font(.title3.bold())
                .foregroundStyle(.red)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.white, .red)
                        .offset(x: 6, y: 5)
                }
                .frame(width: compact ? 56 : 52, height: 48)
                .background(.red.opacity(0.15), in: Capsule())
        }
        .accessibilityLabel(keepsSome ? "Reject the rest of this burst" : "Reject this burst")
    }

    private func crownButton(compact: Bool) -> some View {
        Button {
            keepThisOne()
        } label: {
            Image(systemName: "crown.fill")
                .font(.title3.bold())
                .foregroundStyle(.yellow)
                .frame(width: compact ? 56 : 52, height: 48)
                .background(.yellow.opacity(0.15), in: Capsule())
        }
    }

    private func ratingButton(_ verdict: Verdict, icon: String, color: Color, compact: Bool = false) -> some View {
        let isActive = currentAsset.flatMap { model.verdict(for: $0) } == verdict
        return Button {
            guard let asset = currentAsset else { return }
            if isActive {
                // Unrank: tapping the active rating clears back to undecided,
                // staying on the photo.
                model.setVerdict(nil, for: asset)
            } else {
                model.setVerdict(verdict, for: asset)
                advance()
            }
        } label: {
            // Selected state is unmistakable: solid fill, white glyph + ring,
            // slight growth. Unselected is a quiet tint.
            Image(systemName: isActive ? "checkmark" : icon)
                .font(.title2.bold())
                .foregroundStyle(isActive ? .white : color)
                .frame(width: compact ? 64 : 76, height: 48)
                .background(isActive ? color : color.opacity(0.15), in: Capsule())
                .overlay(Capsule().strokeBorder(.white, lineWidth: isActive ? 2 : 0))
                .scaleEffect(isActive ? 1.06 : 1)
                .animation(.snappy(duration: 0.15), value: isActive)
        }
        .disabled(currentAsset == nil)
    }

    /// Every photo kept or rejected ("maybe" still counts as undecided).
    private var allDecided: Bool {
        model.items.allSatisfy { item in
            let verdict = model.verdict(for: item)
            return verdict == .keep || verdict == .reject
        }
    }

    private func isUndecided(_ item: CullItem) -> Bool {
        let verdict = model.verdict(for: item)
        return verdict != .keep && verdict != .reject
    }

    private func isUndecided(id: String) -> Bool {
        model.item(withID: id).map(isUndecided) ?? false
    }

    /// Down the burst, then the next stack; past the end, the first
    /// undecided photo. The done card only once everything is decided.
    private func advance() {
        guard !allDecided else { return withAnimation { showsCompletion = true } }
        guard let current = currentAsset,
              let next = model.order.advance(from: current.id, isUndecided: isUndecided(id:)) else { return }
        go(to: next)
    }

    /// After deciding a whole burst: on to the next stack.
    private func advanceToNextStack() {
        guard !allDecided else { return withAnimation { showsCompletion = true } }
        guard let current = currentAsset,
              let next = model.order.advanceToNextStack(from: current.id, isUndecided: isUndecided(id:)) else { return }
        go(to: next)
    }

    /// "Keep this one": keeps the visible frame, rejects every other frame
    /// of the burst, moves on.
    private func keepThisOne() {
        guard let current = currentAsset else { return }
        let changes = currentStackItems.map { (item: $0, verdict: Verdict?.some($0.id == current.id ? .keep : .reject)) }
        model.setVerdicts(changes)  // one undo step
        advanceToNextStack()
    }

    /// Rejects every frame of the burst you haven't kept (all of them if
    /// none are), as one undo step, and moves on.
    private func rejectBurst() {
        let changes = currentStackItems
            .filter { model.verdict(for: $0) != .keep }
            .map { (item: $0, verdict: Verdict?.some(.reject)) }
        model.setVerdicts(changes)
        advanceToNextStack()
    }

    /// The frame we'd bet on (a hint, never a selection).
    private func bestMemberID(in members: [CullItem]) -> String? {
        model.bestMemberID(among: members.map(\.id))
    }
}

/// One pager frame. Its own View (not an inline builder) on purpose: the
/// loader's `revision` must be read in a `body` SwiftUI tracks. Read inside
/// the paged TabView/ScrollView content closures, invalidations were dropped
/// and frames sat on the spinner until any unrelated state change ("image
/// stuck until tap").
private struct PagerFrameView: View {
    let loader: PagerImageLoader?
    let itemID: String
    let record: AssetIndexRecord?
    let showsAFOverlay: Bool
    let onZoomChange: (Bool) -> Void

    var body: some View {
        ZStack {
            let _ = loader?.revision
            if let image = loader?.cachedImage(for: itemID) {
                ZoomablePhotoView(
                    image: image,
                    focusLocation: record?.focusLocation,
                    salientRect: record?.salientRect,
                    horizonDegrees: record?.horizonDegrees,
                    showsAFOverlay: showsAFOverlay,
                    onZoomChange: onZoomChange
                )
            } else if loader == nil {
                Color.black  // far from view: not loading, nothing to animate
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipped()
    }
}

/// Every frame of the current burst at once (expanded layout), as a strip
/// below the photo: verdict dot, best-frame star, current frame ringed. Tap
/// to jump to a frame.
private struct BurstFilmstrip: View {
    @Environment(AppModel.self) private var model
    let items: [CullItem]
    let currentID: String?
    let bestID: String?
    /// Verdict changes must redraw the dots (the journal isn't observable).
    let revision: Int
    let onSelect: (String) -> Void
    @State private var thumbs: [String: UIImage] = [:]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items) { item in
                        Button { onSelect(item.id) } label: { cell(item) }
                            .buttonStyle(.plain)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 10)
            }
            .onChange(of: currentID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .task(id: "\(items.map(\.id))#\(model.imageRevision)") {
            for item in items {
                model.imageProvider.requestThumbnail(for: item, targetSize: CGSize(width: 300, height: 300)) { image in
                    if let image { thumbs[item.id] = image }
                }
            }
        }
    }

    private func cell(_ item: CullItem) -> some View {
        let _ = revision
        let verdict = model.verdict(for: item)
        // Each cell takes its photo's own aspect at a fixed height, so
        // portrait frames aren't cropped to a landscape tile.
        let image = thumbs[item.id]
        let aspect = image.map { $0.size.width / max($0.size.height, 1) } ?? 1.5
        return ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color(white: 0.12)
            }
        }
        .frame(width: 68 * aspect, height: 68)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .opacity(verdict == .reject ? 0.4 : 1)
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(.yellow, lineWidth: item.id == currentID ? 2 : 0))
        .overlay(alignment: .topTrailing) {
            if verdict == .keep || verdict == .reject {
                Circle().fill(verdict == .keep ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    .padding(5)
            }
        }
        .overlay(alignment: .topLeading) {
            if item.id == bestID {
                Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow).padding(5)
            }
        }
    }
}
