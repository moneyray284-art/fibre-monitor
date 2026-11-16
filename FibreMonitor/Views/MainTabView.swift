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
            AppIconManager.apply(settings.appIconChoice)
            if !viewModel.awaitingRouterSelection {
                if !viewModel.settings.isConfigured {
                    viewModel.selectedTab = .home
                    showInitialSettings = true
                } else {
                    Task { await viewModel.refreshIfStale(force: true) }
                }
            }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                if !viewModel.awaitingRouterSelection && viewModel.settings.isConfigured && !viewModel.isLoggedOut {
                    Task { await viewModel.refreshIfStale(force: true) }
                }
            case .background:
                viewModel.endForegroundSession()
            default:
                break
            }
        }
        .onChange(of: viewModel.selectedTab) { _ in
            Task { await viewModel.refreshIfStale(maxAge: 10) }
        }
        .onChange(of: settings.appIconChoice) { choice in
            AppIconManager.apply(choice)
        }
    }
}
