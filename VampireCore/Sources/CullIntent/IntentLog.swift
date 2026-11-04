import Foundation

/// A culling decision for one asset.
public enum Verdict: String, Codable, Sendable, CaseIterable {
    case keep
    case reject
    case maybe
}

/// One appended row of the intent log. The log is append-only: undo and redo
/// are themselves records, so the on-disk history is a faithful journal and
/// replaying it reconstructs both the verdict state *and* the undo/redo
/// stacks — sessions resume across launches with undo intact.
public struct IntentRecord: Equatable, Codable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case set
        case undo
        case redo
    }

    public var operation: Operation
    /// Asset the operation applies to. Always present, including for
    /// undo/redo (denormalized for debuggability; replay re-derives it too).
    public var assetID: String
    /// For `.set`: the new verdict (nil clears). For undo/redo: the verdict
    /// the asset ends up with after the operation.
    public var verdict: Verdict?
    public var timestamp: Date
    /// Shared by the `.set` records of one batch (e.g. "reject this burst"),
    /// which undo and redo as a single step. Undo/redo records stay one per
    /// asset, so replay needs no batch logic beyond the sets.
    public var batchID: String?

    public init(operation: Operation, assetID: String, verdict: Verdict?, timestamp: Date,
                batchID: String? = nil) {
        self.operation = operation
        self.assetID = assetID
        self.verdict = verdict
        self.timestamp = timestamp
        self.batchID = batchID
    }
}

/// In-memory intent log engine. Pure logic — persistence is the caller's job:
/// every mutation emits the appended record through `onAppend`, and a past
/// session is restored by replaying its records through `init(replaying:)`.
///
/// This is the *only* place culling decisions live until "Apply". Nothing in
/// here touches PhotoKit (hard constraint 1: no incremental deletion).
public final class IntentLog {
    private struct Mutation {
        let assetID: String
        let previousVerdict: Verdict?
        let newVerdict: Verdict?
        let batchID: String?
    }

    private(set) public var verdicts: [String: Verdict] = [:]
    private var undoStack: [Mutation] = []
    private var redoStack: [Mutation] = []

    /// Called synchronously with every appended record, in order.
    public var onAppend: ((IntentRecord) -> Void)?
    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Rebuilds state and undo/redo stacks from a journal.
    public convenience init(replaying records: [IntentRecord], now: @escaping () -> Date = Date.init) {
        self.init(now: now)
        for record in records {
            switch record.operation {
            case .set: applySet(record.verdict, for: record.assetID, batchID: record.batchID, journal: false)
            case .undo: applyUndo(journal: false)
            case .redo: applyRedo(journal: false)
            }
        }
    }

    // MARK: - Queries

    public func verdict(for assetID: String) -> Verdict? {
        verdicts[assetID]
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func assetIDs(with verdict: Verdict) -> Set<String> {
        Set(verdicts.filter { $0.value == verdict }.keys)
    }

    public var counts: [Verdict: Int] {
        verdicts.values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    // MARK: - Mutations

    /// Sets (or clears, with nil) the verdict for an asset.
    public func set(_ verdict: Verdict?, for assetID: String) {
        applySet(verdict, for: assetID, batchID: nil, journal: true)
    }

    /// Several decisions as one undo step ("reject this burst", "keep this
    /// one, reject the rest"). No-op entries are skipped.
    public func set(_ changes: [(assetID: String, verdict: Verdict?)]) {
        let batchID = UUID().uuidString
        for change in changes {
            applySet(change.verdict, for: change.assetID, batchID: batchID, journal: true)
        }
    }

    /// Undoes the last step — a whole batch if it was one. Returns the
    /// affected asset (the batch's first) for the UI to bring back.
    @discardableResult
    public func undo() -> String? {
        guard let batchID = undoStack.last?.batchID else { return applyUndo(journal: true) }
        var assetID: String?
        while undoStack.last?.batchID == batchID { assetID = applyUndo(journal: true) }
        return assetID
    }

    @discardableResult
    public func redo() -> String? {
        guard let batchID = redoStack.last?.batchID else { return applyRedo(journal: true) }
        var first: String?
        while redoStack.last?.batchID == batchID {
            let assetID = applyRedo(journal: true)
            if first == nil { first = assetID }
        }
        return first
    }

    // MARK: - Core

    private func applySet(_ verdict: Verdict?, for assetID: String, batchID: String?, journal: Bool) {
        let previous = verdicts[assetID]
        guard previous != verdict else { return } // no-op sets don't pollute history

        store(verdict, for: assetID)
        undoStack.append(Mutation(assetID: assetID, previousVerdict: previous, newVerdict: verdict, batchID: batchID))
        redoStack.removeAll()
        if journal {
            onAppend?(IntentRecord(operation: .set, assetID: assetID, verdict: verdict, timestamp: now(),
                                   batchID: batchID))
        }
    }

    @discardableResult
    private func applyUndo(journal: Bool) -> String? {
        guard let mutation = undoStack.popLast() else { return nil }
        store(mutation.previousVerdict, for: mutation.assetID)
        redoStack.append(mutation)
        if journal {
            onAppend?(IntentRecord(
                operation: .undo, assetID: mutation.assetID,
                verdict: mutation.previousVerdict, timestamp: now()
            ))
        }
        return mutation.assetID
    }

    @discardableResult
    private func applyRedo(journal: Bool) -> String? {
        guard let mutation = redoStack.popLast() else { return nil }
        store(mutation.newVerdict, for: mutation.assetID)
        undoStack.append(mutation)
        if journal {
            onAppend?(IntentRecord(
                operation: .redo, assetID: mutation.assetID,
                verdict: mutation.newVerdict, timestamp: now()
            ))
        }
        return mutation.assetID
    }

    private func store(_ verdict: Verdict?, for assetID: String) {
        if let verdict {
            verdicts[assetID] = verdict
        } else {
            verdicts.removeValue(forKey: assetID)
        }
    }
}
