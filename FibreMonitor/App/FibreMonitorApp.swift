import SwiftUI
import UIKit

@main
struct FibreMonitorApp: App {
    @UIApplicationDelegateAdaptor(LinkWaveAppDelegate.self) private var appDelegate

    init() {
        _ = NetworkMonitor.shared
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
    }
}
