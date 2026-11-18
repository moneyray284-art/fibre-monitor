import SwiftUI

public struct MainTabView: View {
    @StateObject private var viewModel = MonitorViewModel()
    @ObservedObject private var settings = SettingsStore.shared
    @AppStorage("linkwave.surfaceStyle") private var surfaceStyleRawValue = LinkWaveSurfaceStyle.liquidGlass.rawValue
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showInitialSettings = false
    @State private var isLaunchAnimationVisible = true
    @State private var launchAnimationFinished = false
    @State private var presentInitialSettingsAfterLaunch = false
    @State private var foregroundPreparationTask: Task<Void, Never>?
    @State private var foregroundPreparationID: UUID?
    @State private var liveTrafficTask: Task<Void, Never>?
    @State private var liveTrafficID: UUID?
    @State private var foregroundCleanupTask: Task<Void, Never>?
    @State private var foregroundCleanupID: UUID?

    public init() {}

    public var body: some View {
        ZStack {
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
            .linkWaveTabBarSurface()

            if isLaunchAnimationVisible {
                LinkWaveLaunchAnimation(
                    brandColor: settings.logoColor.color(for: effectiveColorScheme),
                    onFinished: finishLaunchAnimation
                )
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .environment(\.linkWaveThemePalette, activeThemePalette)
        .environment(\.linkWaveLogoColor, settings.logoColor.color(for: effectiveColorScheme))
        .environment(\.linkWaveSurfaceStyle, surfaceStyle)
        .foregroundStyle(activeThemePalette.textPrimary.color)
        .statusBarHidden(isLaunchAnimationVisible)
        .sheet(isPresented: routerPickerBinding) {
            RouterLaunchPickerView(viewModel: viewModel)
        }
        .sheet(isPresented: $showInitialSettings, onDismiss: {
            viewModel.settingsDidDismiss()
        }) {
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
        .tint(activeThemePalette.accent.color)
        .onAppear {
            AppIconManager.shared.apply(settings.appIconChoice, logoColor: settings.logoColor)
            presentInitialSettingsAfterLaunch =
                !viewModel.awaitingRouterSelection && !viewModel.settings.isConfigured
            if launchAnimationFinished && presentInitialSettingsAfterLaunch {
                showInitialSettings = true
            }
        }
        .task {
            guard viewModel.settings.isConfigured else { return }
            await viewModel.refreshAll(forceReauthIfNeeded: true)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                beginForegroundMonitoring()
            case .inactive:
                pauseForegroundMonitoring(logout: false)
            case .background:
                pauseForegroundMonitoring(logout: true)
            default:
                pauseForegroundMonitoring(logout: false)
            }
        }
        .onChange(of: viewModel.selectedTab) { _ in
            Haptics.impact()
            guard scenePhase == .active else { return }
            Task { await viewModel.refreshIfStale(maxAge: 10) }
        }
        .onChange(of: viewModel.isForegroundSessionReady) { isReady in
            if isReady {
                startLiveTrafficFeed()
            } else {
                liveTrafficTask?.cancel()
            }
        }
        .onChange(of: settings.appIconChoice) { choice in
            AppIconManager.shared.apply(choice, logoColor: settings.logoColor)
        }
        .onChange(of: settings.logoColor) { logoColor in
            AppIconManager.shared.apply(settings.appIconChoice, logoColor: logoColor)
        }
    }

    private var effectiveColorScheme: ColorScheme {
        switch settings.theme {
        case .system: systemColorScheme
        case .light: .light
        case .dark: .dark
        }
    }

    private var activeThemePalette: ThemePalette {
        settings.themePalette(for: effectiveColorScheme)
    }

    private var surfaceStyle: LinkWaveSurfaceStyle {
        LinkWaveSurfaceStyle(rawValue: surfaceStyleRawValue) ?? .liquidGlass
    }

    private var routerPickerBinding: Binding<Bool> {
        Binding(
            get: { launchAnimationFinished && viewModel.awaitingRouterSelection },
            set: { isPresented in
                if !isPresented { viewModel.awaitingRouterSelection = false }
            }
        )
    }

    private func finishLaunchAnimation() {
        withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.3)) {
            isLaunchAnimationVisible = false
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: reduceMotion ? 20_000_000 : 320_000_000)
            launchAnimationFinished = true
            if presentInitialSettingsAfterLaunch {
                showInitialSettings = true
            }
        }
    }

    private func beginForegroundMonitoring() {
        guard scenePhase == .active,
              !viewModel.awaitingRouterSelection,
              viewModel.settings.isConfigured,
              !viewModel.isLoggedOut,
              foregroundPreparationTask == nil else { return }

        let cleanup = foregroundCleanupTask
        let previousLiveTraffic = liveTrafficTask
        let taskID = UUID()
        foregroundPreparationID = taskID
        foregroundPreparationTask = Task { @MainActor in
            await cleanup?.value
            await previousLiveTraffic?.value
            guard !Task.isCancelled, scenePhase == .active else {
                if foregroundPreparationID == taskID {
                    foregroundPreparationTask = nil
                    foregroundPreparationID = nil
                }
                return
            }
            await viewModel.prepareForegroundSession()
            let wasCancelled = Task.isCancelled
            if foregroundPreparationID == taskID {
                foregroundPreparationTask = nil
                foregroundPreparationID = nil
            }
            if wasCancelled {
                if scenePhase == .active { beginForegroundMonitoring() }
                return
            }
            if viewModel.isForegroundSessionReady {
                startLiveTrafficFeed()
            }
        }
    }

    private func startLiveTrafficFeed() {
        guard scenePhase == .active,
              viewModel.isForegroundSessionReady,
              liveTrafficTask == nil else { return }

        let taskID = UUID()
        liveTrafficID = taskID
        liveTrafficTask = Task { @MainActor in
            await viewModel.runLiveTrafficFeed()
            let wasCancelled = Task.isCancelled
            if liveTrafficID == taskID {
                liveTrafficTask = nil
                liveTrafficID = nil
            }
            if wasCancelled, scenePhase == .active {
                if viewModel.isForegroundSessionReady {
                    startLiveTrafficFeed()
                } else {
                    beginForegroundMonitoring()
                }
            } else if viewModel.isForegroundSessionReady {
                startLiveTrafficFeed()
            }
        }
    }

    private func pauseForegroundMonitoring(logout: Bool) {
        viewModel.pauseForegroundSession()
        let preparation = foregroundPreparationTask
        let liveTraffic = liveTrafficTask
        preparation?.cancel()
        liveTraffic?.cancel()

        guard logout else { return }
        foregroundPreparationTask = nil
        foregroundPreparationID = nil
        liveTrafficTask = nil
        liveTrafficID = nil
        let taskID = UUID()
        foregroundCleanupID = taskID
        foregroundCleanupTask = Task { @MainActor in
            await preparation?.value
            await liveTraffic?.value
            if scenePhase != .active { await viewModel.endForegroundSession() }
            if foregroundCleanupID == taskID {
                foregroundCleanupTask = nil
                foregroundCleanupID = nil
            }
        }
    }
}
