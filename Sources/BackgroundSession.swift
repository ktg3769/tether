import BackgroundTasks
import UIKit

/// Keeps Tether running in the background with iOS 26's continued processing task, in place of the
/// silent sound the original Tether plays. It stands in for that sound behind `KeepAliveSound`.
///
/// iOS takes the request only while Tether is on screen, so `Model` requests it each time Tether
/// comes on screen (opened by hand, by Start Tether, or by an automation's Open App), and the main
/// screen has a button to ask again. The system shows the task in its own Live Activity, where it can
/// be cancelled. Tether sets no time limit of its own: the task runs until it's stopped with the
/// button, cancelled in that Live Activity, ended by iOS, or Tether is closed in the app switcher.
///
/// A proxy has no "done", so progress is a heartbeat: the completed units keep growing and the total
/// stays about twice that, so the bar sits near half and never looks finished or stuck.
@MainActor
final class BackgroundSession: ObservableObject, KeepAliveSound {
    enum Status: Equatable {
        case off
        case submitted
        case running
        case ended(String)
        case failed(String)

        var title: String {
            switch self {
            case .off: "Off"
            case .submitted: "Requested, waiting for iOS"
            case .running: "Running"
            case .ended(let why): "Ended: \(why)"
            case .failed(let why): "Failed: \(why)"
            }
        }
    }

    @Published private(set) var status: Status = .off
    /// What the system's Live Activity says under "Tether". Set by `Model`.
    var subtitle: () -> String = { "Sharing Personal Hotspot" }

    var running: Bool { status == .running }
    /// Requested or running, so it isn't requested twice.
    var active: Bool { status == .running || status == .submitted }

    private static let title = "Tether"
    /// Info.plist allows `$(PRODUCT_BUNDLE_IDENTIFIER).keepalive.*`. Each request gets its own
    /// identifier, because one identifier can be registered only once per launch.
    private static var prefix: String { (Bundle.main.bundleIdentifier ?? "tether") + ".keepalive." }

    private let log: @MainActor (String) -> Void
    private var identifier: String?
    private var task: BGContinuedProcessingTask?
    private var beats: Int64 = 0

    init(log: @escaping @MainActor (String) -> Void) {
        self.log = log
    }

    // MARK: KeepAliveSound, as HotspotSession uses it

    var playing: Bool { running }
    var sounding: Bool { running }

    /// HotspotSession calls this on every watcher round while it wants Tether kept running. A task
    /// can't be requested from here (Tether may be off screen), so it only keeps a running one moving.
    func start() { heartbeat() }

    /// HotspotSession calls this once the hotspot has been gone for 10 minutes, to save battery.
    /// This fork keeps running until it's stopped by hand, so the call is ignored.
    func stop() {}

    // MARK: Requests

    /// Asks iOS for the task. Call only with Tether on screen.
    func request() {
        guard !active else { return }
        // A request left over from an earlier launch could hold up the queue.
        BGTaskScheduler.shared.cancelAllTaskRequests()

        let id = Self.prefix + UUID().uuidString.lowercased()
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, let task = task as? BGContinuedProcessingTask, self.identifier == id else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.attach(task)
            }
        }
        guard registered else {
            fail("couldn't register (bundle ID \(Bundle.main.bundleIdentifier ?? "?") doesn't match Info.plist?)")
            return
        }

        let request = BGContinuedProcessingTaskRequest(identifier: id, title: Self.title, subtitle: subtitle())
        request.strategy = .queue
        identifier = id
        do {
            try BGTaskScheduler.shared.submit(request)
            status = .submitted
            log("background task requested")
        } catch {
            identifier = nil
            fail(Self.describe(error))
        }
    }

    /// The Stop button. Reported as finished, not failed.
    func end() {
        if let task {
            task.expirationHandler = nil
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: true)
        } else if let identifier {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
        task = nil
        identifier = nil
        beats = 0
        status = .off
        log("background task stopped")
    }

    private func heartbeat() {
        guard let task else { return }
        beats += 1
        task.progress.totalUnitCount = beats * 2 + 100
        task.progress.completedUnitCount = beats
        task.updateTitle(Self.title, subtitle: subtitle())
    }

    private func attach(_ task: BGContinuedProcessingTask) {
        self.task = task
        beats = 0
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = 1
        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in self?.expired() }
        }
        status = .running
        log("background task running")
    }

    /// Cancelled in the system's Live Activity, or ended by iOS. iOS suspends Tether after this, and
    /// it's requested again the next time Tether comes on screen.
    private func expired() {
        guard let task else { return }
        self.task = nil
        identifier = nil
        status = .ended("cancelled in the Live Activity or by iOS")
        log("background task expired")
        task.setTaskCompleted(success: false)
    }

    private func fail(_ why: String) {
        status = .failed(why)
        log("background task not started: \(why)")
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? BGTaskScheduler.Error {
            switch error.code {
            case .unavailable: return "not available on this device"
            case .notPermitted: return "identifier not permitted by Info.plist"
            case .tooManyPendingTaskRequests: return "too many pending requests"
            @unknown default: return "BGTaskScheduler error \(error.code.rawValue)"
            }
        }
        return error.localizedDescription
    }
}
