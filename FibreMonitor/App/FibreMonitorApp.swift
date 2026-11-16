import SwiftUI
import UIKit

@main
struct FibreMonitorApp: App {
    @UIApplicationDelegateAdaptor(LinkWaveAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
    }
}
