import Foundation

/// The safe-apply decision, extracted from the session model so it is
/// unit-testable without PhotoKit (hard constraint 1: culling decisions are
/// committed once, batched, at Apply — never incrementally, and never from
/// a camera session).
///
/// This is deliberately NOT a PhotoKit wrapper: it answers one question —
/// what will a non-dry-run Apply do — and nothing more. The destructive half
/// (`PhotoKit.PHPhotoLibrary.performChanges`) stays in the app, thin and
/// untested, straight off this plan.
public struct ApplyPlan: Sendable, Equatable {
    /// Assets whose originals will be deleted.
    public let rejects: [String]
    /// Assets that are kept (never deleted, never flagged).
    public let keeps: [String]
    public let isLibrarySession: Bool
    public let dryRun: Bool

    /// Throws `nothingToApply` when there is no reject and no keep, and
    /// `notALibrarySession` for camera sessions — their Apply is an import,
    /// never a deletion (hard rule: never delete off the card).
    public init(rejects: [String], keeps: [String], isLibrarySession: Bool, dryRun: Bool) throws {
        guard isLibrarySession else { throw ApplyPlanError.notALibrarySession }
        guard !rejects.isEmpty || !keeps.isEmpty else { throw ApplyPlanError.nothingToApply }
        self.rejects = rejects
        self.keeps = keeps
        self.isLibrarySession = isLibrarySession
        self.dryRun = dryRun
    }

    /// `true` when a non-dry-run Apply will mutate the Photos library at all.
    /// A keeps-only plan (nothing rejected) or a dry run is side-effect-free:
    /// it reports a summary but touches nothing.
    public var mutatesLibrary: Bool { !dryRun && !rejects.isEmpty }
}

public enum ApplyPlanError: Error, Equatable {
    case nothingToApply
    case notALibrarySession
}
