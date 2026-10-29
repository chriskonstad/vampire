import BackgroundTasks
import UIKit

/// Keeps a user-started bulk operation (importing keepers off the camera)
/// running when the app is backgrounded or the phone locks, via iOS 26's
/// `BGContinuedProcessingTask`. The system shows it as a Live Activity —
/// Dynamic Island + Lock Screen — with our title, subtitle and progress and
/// a cancel control, so no widget extension is needed.
///
/// Must be started from a foreground user action (the Import tap). Where the
/// scheduler refuses (simulator, background activity disabled, system load),
/// it falls back to a classic `beginBackgroundTask` (~30s grace) — the
/// import itself is resumable either way.
@MainActor
final class ContinuedWork {
    /// Prefix of every submitted identifier; Info.plist permits `<prefix>.*`.
    static let identifierPrefix = "com.chriskonstad.vampire.import"

    private(set) var title: String
    private(set) var subtitle: String
    /// Units are arbitrary (bytes for imports); the system shows a fraction.
    let progress = Progress(totalUnitCount: 1)

    private var task: BGContinuedProcessingTask?
    private var fallback: UIBackgroundTaskIdentifier = .invalid
    /// True when the system accepted the continued-processing request, i.e.
    /// the work survives backgrounding/locking with a system Live Activity.
    private(set) var isContinued = false
    private var finished = false
    private let onExpire: @MainActor () -> Void

    /// `onExpire` runs if the user cancels from the Live Activity or the
    /// system ends the task: stop work promptly (partial files are kept).
    init(title: String, subtitle: String, onExpire: @escaping @MainActor () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.onExpire = onExpire
        start()
    }

    private func start() {
        let identifier = "\(Self.identifierPrefix).\(UUID().uuidString)"
        // Continued-processing handlers may be registered at any time (they're
        // exempt from the before-launch-finishes rule) — once per identifier.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.attach(task)
            }
        }
        guard registered else { return startFallback("registration refused") }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail  // run now or not at all: the user is waiting on it
        do {
            try BGTaskScheduler.shared.submit(request)
            isContinued = true
        } catch {
            startFallback("\(error)")
        }
    }

    private func attach(_ task: BGContinuedProcessingTask) {
        guard !finished else { task.setTaskCompleted(success: true); return }
        self.task = task
        task.progress.totalUnitCount = progress.totalUnitCount
        task.progress.completedUnitCount = progress.completedUnitCount
        task.updateTitle(title, subtitle: subtitle)
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, !self.finished else { return }
                self.onExpire()
                self.finish(success: false)
            }
        }
    }

    private func startFallback(_ reason: String) {
        log.info("continued processing unavailable (\(reason, privacy: .public)); using background task")
        fallback = UIApplication.shared.beginBackgroundTask(withName: "camera-import") { [weak self] in
            Task { @MainActor in self?.endFallback() }
        }
    }

    private func endFallback() {
        if fallback != .invalid { UIApplication.shared.endBackgroundTask(fallback) }
        fallback = .invalid
    }

    /// Progress must keep moving: the scheduler expires tasks that look stalled.
    func update(completed: Int64, total: Int64, subtitle: String? = nil) {
        progress.totalUnitCount = max(total, 1)
        progress.completedUnitCount = min(completed, progress.totalUnitCount)
        task?.progress.totalUnitCount = progress.totalUnitCount
        task?.progress.completedUnitCount = progress.completedUnitCount
        if let subtitle, subtitle != self.subtitle {
            self.subtitle = subtitle
            task?.updateTitle(title, subtitle: subtitle)
        }
    }

    /// Exactly once, on every terminal path.
    func finish(success: Bool) {
        guard !finished else { return }
        finished = true
        if let task {
            task.progress.completedUnitCount = success ? task.progress.totalUnitCount : task.progress.completedUnitCount
            task.setTaskCompleted(success: success)
        }
        task = nil
        endFallback()
    }
}
