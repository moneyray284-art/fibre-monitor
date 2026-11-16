import BackgroundTasks
import UIKit

@MainActor
final class LinkWaveAppDelegate: NSObject, UIApplicationDelegate {
    static let refreshIdentifier = "com.linkwave.refresh"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                LinkWaveBackgroundRefresh.handle(refreshTask)
            }
        }
        LinkWaveBackgroundRefresh.scheduleNext()
        return true
    }
}

@MainActor
enum LinkWaveBackgroundRefresh {
    static func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: LinkWaveAppDelegate.refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // iOS may defer or reject a refresh request when background refresh is unavailable.
        }
    }

    static func handle(_ task: BGAppRefreshTask) {
        scheduleNext()
        let completion = BackgroundTaskCompletion(task: task)
        let work = Task { @MainActor in
            let success = await snapshotUsage()
            completion.finish(success: success)
        }
        task.expirationHandler = {
            work.cancel()
            completion.finish(success: false)
        }
    }

    private static func snapshotUsage() async -> Bool {
        let settings = SettingsStore.shared
        guard let profile = settings.activeProfile,
              profile.resolvedRouterType == .huaweiONT,
              settings.isConfigured else { return false }

        let provider = RouterProviderFactory.make(
            profile: profile,
            credentials: settings.credentials,
            transport: URLSessionOntTransport()
        )
        do {
            let traffic = try await provider.pollTraffic(now: Date())
            guard let download = traffic.cumulativeDownloadBytes,
                  let upload = traffic.cumulativeUploadBytes else {
                await provider.logout()
                return false
            }
            let sampledAt = Date()
            settings.recordTrafficCounters(download: download, upload: upload, for: profile.id, at: sampledAt)
            settings.recordSuccessfulSync(for: profile.id, at: sampledAt)
            WidgetSnapshotStore.updateUsage(summary: settings.dataUsageSummary, at: sampledAt)
            await provider.logout()
            return true
        } catch {
            await provider.logout()
            return false
        }
    }
}

private final class BackgroundTaskCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var isCompleted = false
    private let task: BGTask

    init(task: BGTask) {
        self.task = task
    }

    func finish(success: Bool) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        lock.unlock()
        task.setTaskCompleted(success: success)
    }
}
