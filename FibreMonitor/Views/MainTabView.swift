import SwiftUI

public struct MainTabView: View {
    @StateObject private var viewModel = MonitorViewModel()
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showInitialSettings = false

    public init() {}

    public var body: some View {
        TabView(selection: $viewModel.selectedTab) {
            DashboardView(viewModel: viewModel)
                .tabItem {
                    Label("Home", systemImage: "house")
                }
                .tag(AppTab.home)

            UsageTabView(viewModel: viewModel)
                .tabItem {
                    Label("Usage", systemImage: "arrow.up.arrow.down.circle")
                }
                .tag(AppTab.usage)

            ClientsTabView(viewModel: viewModel)
                .tabItem {
                    Label("Clients", systemImage: "laptopcomputer.and.iphone")
                }
                .tag(AppTab.clients)

            WifiTabView(viewModel: viewModel)
                .tabItem {
                    Label("Wi-Fi", systemImage: "wifi")
                }
                .tag(AppTab.wifi)

        }
        .sheet(isPresented: $viewModel.awaitingRouterSelection) {
            RouterLaunchPickerView(viewModel: viewModel)
        }
        .sheet(isPresented: $showInitialSettings) {
            NavigationStack {
                SettingsTabView(viewModel: viewModel)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { showInitialSettings = false }
                        }
                    }
            }
        }
        .alert(
            viewModel.actionMessage ?? "",
            isPresented: Binding(
                get: { viewModel.actionMessage != nil },
                set: { if !$0 { viewModel.actionMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        }
        .preferredColorScheme(settings.theme.colorScheme)
        .tint(settings.accentColor.color)
        .onAppear {
            if !viewModel.awaitingRouterSelection {
                if !viewModel.settings.isConfigured {
                    viewModel.selectedTab = .home
                    showInitialSettings = true
                } else {
                    viewModel.startPolling()
                }
            }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                if !viewModel.awaitingRouterSelection && viewModel.settings.isConfigured && !viewModel.isLoggedOut {
                    viewModel.startPolling()
                }
            case .background:
                viewModel.stopPolling()
            default:
                break
            }
        }
    }
}

