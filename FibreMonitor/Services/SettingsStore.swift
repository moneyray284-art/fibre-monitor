import Foundation
import Security
import SwiftUI

public enum AppTheme: String, CaseIterable, Identifiable, Hashable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

public enum AppAccentColor: String, CaseIterable, Identifiable, Hashable {
    case blue
    case green
    case purple
    case orange

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    public var color: Color {
        switch self {
        case .blue: .blue
        case .green: .green
        case .purple: .purple
        case .orange: .orange
        }
    }
}

public enum AppIconChoice: String, CaseIterable, Identifiable, Hashable {
    case orange
    case blue
    case purple
    case green

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var alternateIconName: String { "AppIcon\(title)" }

    public static func matching(_ accent: AppAccentColor) -> AppIconChoice {
        switch accent {
        case .blue: .blue
        case .green: .green
        case .purple: .purple
        case .orange: .orange
        }
    }
}

/// Seam around Keychain password storage so unit tests can inspect per-profile accounts.
public protocol PasswordStore {
    func password(forAccount account: String) -> String?
    func setPassword(_ password: String, forAccount account: String)
    func deletePassword(forAccount account: String)
}

/// Keychain storage for router passwords, one item per profile UUID under `dev.mattdev0.fibremonitor.router`.
public final class SystemKeychainStore: PasswordStore {
    public static let defaultService = "dev.mattdev0.fibremonitor.router"
    private let service: String

    public init(service: String = defaultService) {
        self.service = service
    }

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func password(forAccount account: String) -> String? {
        var q = query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setPassword(_ password: String, forAccount account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
        guard !password.isEmpty else { return }
        var q = query(account: account)
        q[kSecValueData as String] = Data(password.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    public func deletePassword(forAccount account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}

/// Connection profiles and preferences. Each profile's password lives in the Keychain; metadata lives in UserDefaults.
@MainActor
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()

    private enum Keys {
        static let profiles = "router_profiles"
        static let activeProfileId = "active_router_profile_id"
        static let profileAliases = "profile_device_aliases"
        static let theme = "app_theme"
        static let accentColor = "app_accent_color"
        static let appIconChoice = "app_icon_choice"
        static let autoMatchAppIcon = "auto_match_app_icon"
        static let dataUsage = "data_usage_v1"
        static let sharedDailyUsage = "linkwave.daily_usage.history.v1"
        static let migrated = "v2_profiles_migrated"

        // Legacy 1.x keys
        static let legacyHost = "router_host"
        static let legacyUsername = "router_username"
        static let legacyAliases = "device_aliases"
        static let legacyKeychainAccount = "router"
    }

    private let defaults: UserDefaults
    private let sharedDefaults: UserDefaults
    private let passwordStore: PasswordStore
    private var usageByProfile: [String: ProfileUsage] = [:]

    @Published public private(set) var profiles: [RouterProfile] = []
    /// Publishes in-app credential writes, including Keychain updates, to the shared router model.
    @Published public private(set) var routerCredentialsRevision: UInt64 = 0
    @Published public var activeProfileId: UUID? {
        didSet {
            saveActiveProfileId()
            refreshDataUsageSummary()
        }
    }
    @Published public var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }
    @Published public var accentColor: AppAccentColor {
        didSet {
            defaults.set(accentColor.rawValue, forKey: Keys.accentColor)
            if autoMatchAppIconToAccentColor {
                appIconChoice = AppIconChoice.matching(accentColor)
            }
        }
    }
    @Published public var appIconChoice: AppIconChoice {
        didSet { defaults.set(appIconChoice.rawValue, forKey: Keys.appIconChoice) }
    }
    @Published public var autoMatchAppIconToAccentColor: Bool {
        didSet {
            defaults.set(autoMatchAppIconToAccentColor, forKey: Keys.autoMatchAppIcon)
            if autoMatchAppIconToAccentColor {
                appIconChoice = AppIconChoice.matching(accentColor)
            }
        }
    }
    @Published public private(set) var dataUsageSummary = DataUsageSummary()
    @Published public private(set) var profileAliases: [String: [String: String]] = [:]

    private struct ProfileUsage: Codable {
        struct Day: Codable {
            var downloadBytes: UInt64 = 0
            var uploadBytes: UInt64 = 0
        }

        var lastDownloadCounter: UInt64?
        var lastUploadCounter: UInt64?
        var totalDownloadBytes: UInt64 = 0
        var totalUploadBytes: UInt64 = 0
        var days: [String: Day] = [:]
        var chartStartDayKey: String?
        // Optional so data saved by earlier versions still decodes.
        var lastCounterSampleAt: Date?
        var lastSuccessfulSyncAt: Date?
        var observedDayKeys: [String]?
        var incompleteDayKeys: [String]?
        var lastConnectionObservationAt: Date?
        var connectionInterruptions: [ConnectionInterruption]?
    }

    private struct SharedDailyUsageHistory: Codable {
        struct Day: Codable {
            var downloadBytes: UInt64
            var uploadBytes: UInt64
        }

        struct Profile: Codable {
            var chartStartDayKey: String?
            var days: [String: Day]
        }

        var profiles: [String: Profile]
    }

    public init(
        defaults: UserDefaults = .standard,
        passwordStore: PasswordStore = SystemKeychainStore(),
        sharedDefaults: UserDefaults? = nil
    ) {
        self.defaults = defaults
        if let sharedDefaults {
            self.sharedDefaults = sharedDefaults
        } else if defaults === UserDefaults.standard {
            self.sharedDefaults = UserDefaults(suiteName: RouterSnapshotCache.appGroupID) ?? defaults
        } else {
            self.sharedDefaults = defaults
        }
        self.passwordStore = passwordStore

        self.theme = AppTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system
        let accentColor = AppAccentColor(rawValue: defaults.string(forKey: Keys.accentColor) ?? "") ?? .blue
        self.accentColor = accentColor
        let autoMatchAppIcon = defaults.object(forKey: Keys.autoMatchAppIcon) as? Bool ?? true
        self.autoMatchAppIconToAccentColor = autoMatchAppIcon
        let savedIcon = AppIconChoice(rawValue: defaults.string(forKey: Keys.appIconChoice) ?? "") ?? .orange
        self.appIconChoice = autoMatchAppIcon ? AppIconChoice.matching(accentColor) : savedIcon
        if let data = defaults.data(forKey: Keys.dataUsage),
           let decoded = try? JSONDecoder().decode([String: ProfileUsage].self, from: data) {
            self.usageByProfile = decoded
        }
        mergeSharedDailyUsageHistory()

        if defaults.bool(forKey: Keys.migrated) || defaults.data(forKey: Keys.profiles) != nil {
            if let data = defaults.data(forKey: Keys.profiles),
               let decoded = try? JSONDecoder().decode([RouterProfile].self, from: data) {
                self.profiles = decoded
            }
            self.profileAliases = defaults.dictionary(forKey: Keys.profileAliases) as? [String: [String: String]] ?? [:]
            if let idStr = defaults.string(forKey: Keys.activeProfileId),
               let uuid = UUID(uuidString: idStr),
               profiles.contains(where: { $0.id == uuid }) {
                self.activeProfileId = uuid
            } else {
                self.activeProfileId = profiles.first?.id
            }
        } else {
            migrateFromV1()
        }
        refreshDataUsageSummary()
    }

    public var activeProfile: RouterProfile? {
        if let activeProfileId, let match = profiles.first(where: { $0.id == activeProfileId }) {
            return match
        }
        return profiles.first
    }

    public var host: String { activeProfile?.host ?? "" }
    public var username: String { activeProfile?.username ?? "root" }

    public var password: String {
        guard let id = activeProfile?.id else { return "" }
        return password(for: id)
    }

    public var isConfigured: Bool {
        activeProfile != nil && !host.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    public var connectionHistory: [ConnectionInterruption] {
        guard let profileId = activeProfile?.id,
              let events = usageByProfile[profileId.uuidString]?.connectionInterruptions else { return [] }
        return events.sorted { $0.startedAt > $1.startedAt }
    }

    public var credentials: HuaweiOntClient.Credentials {
        .init(
            host: host.trimmingCharacters(in: .whitespaces),
            username: username.trimmingCharacters(in: .whitespaces),
            password: password
        )
    }

    public func password(for profileId: UUID) -> String {
        passwordStore.password(forAccount: profileId.uuidString) ?? ""
    }

    public func setPassword(_ password: String, for profileId: UUID) {
        passwordStore.setPassword(password, forAccount: profileId.uuidString)
        if activeProfileId == profileId { routerCredentialsRevision &+= 1 }
        objectWillChange.send()
    }

    // MARK: Profile management

    @discardableResult
    public func addProfile(_ profile: RouterProfile, password: String, select: Bool = true) -> RouterProfile {
        var item = profile
        item.name = Self.cleanName(item.name, fallbackHost: item.host)
        item.host = item.host.trimmingCharacters(in: .whitespaces)
        item.username = Self.cleanUsername(item.username)
        if select { item.lastUsed = Date() }

        profiles.append(item)
        setPassword(password, for: item.id)
        if select || activeProfileId == nil {
            activeProfileId = item.id
        }
        saveProfiles()
        return item
    }

    public func updateProfile(_ profile: RouterProfile, password: String? = nil) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var updated = profile
        updated.name = Self.cleanName(updated.name, fallbackHost: updated.host)
        updated.host = updated.host.trimmingCharacters(in: .whitespaces)
        updated.username = Self.cleanUsername(updated.username)
        profiles[index] = updated
        if let password {
            setPassword(password, for: updated.id)
        } else if activeProfileId == updated.id {
            routerCredentialsRevision &+= 1
        }
        saveProfiles()
    }

    public func deleteProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        passwordStore.deletePassword(forAccount: id.uuidString)
        usageByProfile.removeValue(forKey: id.uuidString)
        saveUsage()
        profileAliases.removeValue(forKey: id.uuidString)
        saveAliases()
        if activeProfileId == id {
            activeProfileId = profiles.first?.id
        }
        saveProfiles()
    }

    public func moveProfiles(fromOffsets source: IndexSet, toOffset destination: Int) {
        profiles.move(fromOffsets: source, toOffset: destination)
        saveProfiles()
    }

    public func selectProfile(_ id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].lastUsed = Date()
        activeProfileId = id
        saveProfiles()
        refreshDataUsageSummary()
    }

    /// Records cumulative WAN counters. Counter deltas can catch up after a pause, but a long
    /// interval cannot be split accurately across days, so every affected day is marked incomplete.
    public func recordTrafficCounters(download: UInt64, upload: UInt64, for profileId: UUID, at date: Date = Date()) {
        let key = profileId.uuidString
        var usage = usageByProfile[key] ?? ProfileUsage()
        var observedDays = Set(usage.observedDayKeys ?? Array(usage.days.keys))
        var incompleteDays = Set(usage.incompleteDayKeys ?? [])

        if let previousSample = usage.lastCounterSampleAt {
            let calendar = Calendar.current
            var cursor = calendar.startOfDay(for: previousSample)
            let finalDay = calendar.startOfDay(for: date)
            var daysMarked = 0
            if cursor < finalDay {
                while cursor <= finalDay && daysMarked < 367 {
                    incompleteDays.insert(Self.dayKey(for: cursor))
                    daysMarked += 1
                    guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                    cursor = next
                }
            }
        }

        let dayKey = Self.dayKey(for: date)
        if usage.chartStartDayKey == nil {
            usage.chartStartDayKey = usage.days.keys.min() ?? observedDays.min() ?? dayKey
        }
        observedDays.insert(dayKey)
        usage.lastCounterSampleAt = date

        guard let previousDownload = usage.lastDownloadCounter,
              let previousUpload = usage.lastUploadCounter else {
            usage.lastDownloadCounter = download
            usage.lastUploadCounter = upload
            // The initial counter read is only a baseline; it does not reveal earlier traffic today.
            incompleteDays.insert(dayKey)
            usage.observedDayKeys = observedDays.sorted()
            usage.incompleteDayKeys = incompleteDays.sorted()
            usageByProfile[key] = usage
            saveUsage()
            refreshDataUsageSummary()
            return
        }

        let downloadDelta = Self.usageCounterDelta(previous: previousDownload, current: download)
        let uploadDelta = Self.usageCounterDelta(previous: previousUpload, current: upload)
        usage.lastDownloadCounter = download
        usage.lastUploadCounter = upload
        usage.totalDownloadBytes += downloadDelta
        usage.totalUploadBytes += uploadDelta

        var day = usage.days[dayKey] ?? ProfileUsage.Day()
        day.downloadBytes += downloadDelta
        day.uploadBytes += uploadDelta
        usage.days[dayKey] = day

        usage.observedDayKeys = observedDays.sorted()
        usage.incompleteDayKeys = incompleteDays.sorted()

        usageByProfile[key] = usage
        saveUsage()
        refreshDataUsageSummary()
    }

    public func recordSuccessfulSync(for profileId: UUID, at date: Date = Date()) {
        var usage = usageByProfile[profileId.uuidString] ?? ProfileUsage()
        if let lastSync = usage.lastSuccessfulSyncAt, date.timeIntervalSince(lastSync) < 60 {
            return
        }
        usage.lastSuccessfulSyncAt = date
        usageByProfile[profileId.uuidString] = usage
        saveUsage()
        refreshDataUsageSummary()
    }

    /// Saves observed router reachability transitions. Call only while the app is actively syncing.
    public func recordConnectionObservation(
        isReachable: Bool,
        for profileId: UUID,
        at date: Date = Date(),
        interruptionStartedAt: Date? = nil
    ) {
        var usage = usageByProfile[profileId.uuidString] ?? ProfileUsage()
        var events = usage.connectionInterruptions ?? []

        if isReachable {
            guard let index = events.lastIndex(where: { $0.restoredAt == nil }) else { return }
            let observationGap = usage.lastConnectionObservationAt.map { date.timeIntervalSince($0) } ?? .infinity
            events[index].restoredAt = date
            if observationGap <= 60 {
                events[index].observedDurationSeconds = max(0, date.timeIntervalSince(events[index].startedAt))
            }
        } else if events.contains(where: { $0.restoredAt == nil }) {
            if let lastObservation = usage.lastConnectionObservationAt,
               date.timeIntervalSince(lastObservation) < 30 {
                return
            }
        } else {
            events.append(ConnectionInterruption(startedAt: interruptionStartedAt ?? date))
        }

        usage.lastConnectionObservationAt = date
        usage.connectionInterruptions = Array(events.suffix(100))
        usageByProfile[profileId.uuidString] = usage
        saveUsage()
        refreshDataUsageSummary()
    }

    private func refreshDataUsageSummary() {
        guard let profileId = activeProfile?.id else {
            dataUsageSummary = DataUsageSummary()
            return
        }

        let profileKey = profileId.uuidString
        var usage = usageByProfile[profileKey] ?? ProfileUsage()
        let todayKey = Self.dayKey(for: Date())
        let monthPrefix = String(todayKey.prefix(7))
        let monthDays = usage.days.filter { $0.key.hasPrefix(monthPrefix) }.values
        let incompleteDays = Set(usage.incompleteDayKeys ?? [])
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var anchorChanged = false
        if usage.chartStartDayKey == nil {
            usage.chartStartDayKey = usage.days.keys.min()
                ?? usage.observedDayKeys?.min()
                ?? todayKey
            anchorChanged = true
        }

        var chartStart: Date
        if let storedChartStart = usage.chartStartDayKey.flatMap(Self.date(fromDayKey:)) {
            chartStart = storedChartStart
        } else {
            chartStart = today
            if usage.chartStartDayKey != todayKey {
                usage.chartStartDayKey = todayKey
                anchorChanged = true
            }
        }
        let elapsedDays = calendar.dateComponents([.day], from: chartStart, to: today).day ?? 0
        if elapsedDays >= 7 {
            let elapsedWindows = elapsedDays / 7
            chartStart = calendar.date(byAdding: .day, value: elapsedWindows * 7, to: chartStart) ?? today
            usage.chartStartDayKey = Self.dayKey(for: chartStart)
            anchorChanged = true
        }

        if anchorChanged {
            usageByProfile[profileKey] = usage
            saveUsage()
        }

        let history = (0..<7).compactMap { offset -> DailyUsagePoint? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: chartStart) else { return nil }
            let key = Self.dayKey(for: date)
            let day = usage.days[key] ?? ProfileUsage.Day()
            let hasRecordedBytes = day.downloadBytes > 0 || day.uploadBytes > 0
            let hasUsableReading = date <= today && hasRecordedBytes
            return DailyUsagePoint(
                date: date,
                label: date.formatted(.dateTime.month(.abbreviated).day()),
                downloadBytes: hasUsableReading ? day.downloadBytes : nil,
                uploadBytes: hasUsableReading ? day.uploadBytes : nil,
                isPartial: hasUsableReading && incompleteDays.contains(key)
            )
        }
        let historicalDayKeys = Set(usage.days.keys).union(usage.observedDayKeys ?? [])
        let historicalHistory = historicalDayKeys.sorted().compactMap { key -> DailyUsagePoint? in
            guard let date = Self.date(fromDayKey: key), date <= today else { return nil }
            let hasSavedCounters = usage.days[key] != nil
            let day = usage.days[key] ?? ProfileUsage.Day()
            return DailyUsagePoint(
                date: date,
                label: date.formatted(.dateTime.day()),
                downloadBytes: hasSavedCounters ? day.downloadBytes : nil,
                uploadBytes: hasSavedCounters ? day.uploadBytes : nil,
                isPartial: hasSavedCounters && incompleteDays.contains(key)
            )
        }
        dataUsageSummary = DataUsageSummary(
            todayDownloadBytes: usage.days[todayKey]?.downloadBytes ?? 0,
            todayUploadBytes: usage.days[todayKey]?.uploadBytes ?? 0,
            monthDownloadBytes: monthDays.reduce(0) { $0 + $1.downloadBytes },
            monthUploadBytes: monthDays.reduce(0) { $0 + $1.uploadBytes },
            totalDownloadBytes: usage.totalDownloadBytes,
            totalUploadBytes: usage.totalUploadBytes,
            lastSuccessfulSyncAt: usage.lastSuccessfulSyncAt,
            missingHistoryDayCount: history.filter { $0.date <= today && $0.totalBytes == nil }.count,
            dailyHistory: history,
            historicalDailyHistory: historicalHistory
        )
    }

    public func refreshUsageSummaryForCurrentLocalDay() {
        refreshDataUsageSummary()
    }

    /// Restores the latest cached router counters when the profile's local usage store
    /// has not yet been hydrated, without lowering any more recent locally stored totals.
    public func restoreTodayUsageFromRouterSnapshot(
        downloadBytes: UInt64,
        uploadBytes: UInt64,
        for profileId: UUID
    ) {
        guard activeProfile?.id == profileId else { return }
        let profileKey = profileId.uuidString
        var usage = usageByProfile[profileKey] ?? ProfileUsage()
        let key = Self.dayKey(for: Date())
        var day = usage.days[key] ?? ProfileUsage.Day()
        let restoredDownload = max(day.downloadBytes, downloadBytes)
        let restoredUpload = max(day.uploadBytes, uploadBytes)
        guard restoredDownload != day.downloadBytes || restoredUpload != day.uploadBytes else { return }
        day.downloadBytes = restoredDownload
        day.uploadBytes = restoredUpload
        usage.days[key] = day
        usageByProfile[profileKey] = usage
        saveUsage()
        refreshDataUsageSummary()
    }

    private func saveUsage() {
        if let data = try? JSONEncoder().encode(usageByProfile) {
            defaults.set(data, forKey: Keys.dataUsage)
        }

        let sharedProfiles = usageByProfile.mapValues { usage in
            SharedDailyUsageHistory.Profile(
                chartStartDayKey: usage.chartStartDayKey,
                days: usage.days.mapValues {
                    SharedDailyUsageHistory.Day(
                        downloadBytes: $0.downloadBytes,
                        uploadBytes: $0.uploadBytes
                    )
                }
            )
        }
        if let data = try? JSONEncoder().encode(SharedDailyUsageHistory(profiles: sharedProfiles)) {
            sharedDefaults.set(data, forKey: Keys.sharedDailyUsage)
        }
    }

    private func mergeSharedDailyUsageHistory() {
        guard let data = sharedDefaults.data(forKey: Keys.sharedDailyUsage),
              let sharedHistory = try? JSONDecoder().decode(SharedDailyUsageHistory.self, from: data) else {
            return
        }

        for (profileKey, sharedProfile) in sharedHistory.profiles {
            var usage = usageByProfile[profileKey] ?? ProfileUsage()
            for (dayKey, sharedDay) in sharedProfile.days {
                var day = usage.days[dayKey] ?? ProfileUsage.Day()
                day.downloadBytes = max(day.downloadBytes, sharedDay.downloadBytes)
                day.uploadBytes = max(day.uploadBytes, sharedDay.uploadBytes)
                usage.days[dayKey] = day
            }
            if usage.chartStartDayKey == nil {
                usage.chartStartDayKey = sharedProfile.chartStartDayKey
            }
            usageByProfile[profileKey] = usage
        }
    }

    private static func usageCounterDelta(previous: UInt64, current: UInt64) -> UInt64 {
        if current >= previous { return current - previous }
        if previous <= UInt64(UInt32.max), previous > UInt64(UInt32.max) / 2 {
            return (UInt64(UInt32.max) + 1 - previous) + current
        }
        // The WAN session likely reset. Count bytes since the reset and resume from this value.
        return current
    }

    private static func dayKey(for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func date(fromDayKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return Calendar.current.date(from: components)
    }

    public func recordDetection(for profileId: UUID, model: String?, cfgMode: String?) {
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else { return }
        var changed = false
        if let model, !model.isEmpty, profiles[index].detectedModel != model {
            profiles[index].detectedModel = model
            changed = true
        }
        if let cfgMode, !cfgMode.isEmpty, profiles[index].cfgMode != cfgMode {
            profiles[index].cfgMode = cfgMode
            changed = true
        }
        if changed { saveProfiles() }
    }

    // MARK: Per-profile device aliases (keyed by MAC)

    public func alias(for mac: String) -> String? {
        guard let id = activeProfile?.id else { return nil }
        return alias(for: mac, profileId: id)
    }

    public func setAlias(_ alias: String, for mac: String) {
        guard let id = activeProfile?.id else { return }
        setAlias(alias, for: mac, profileId: id)
    }

    public func alias(for mac: String, profileId: UUID) -> String? {
        profileAliases[profileId.uuidString]?[mac.lowercased()]
    }

    public func setAlias(_ alias: String, for mac: String, profileId: UUID) {
        let key = profileId.uuidString
        var dict = profileAliases[key] ?? [:]
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            dict.removeValue(forKey: mac.lowercased())
        } else {
            dict[mac.lowercased()] = trimmed
        }
        if dict.isEmpty {
            profileAliases.removeValue(forKey: key)
        } else {
            profileAliases[key] = dict
        }
        saveAliases()
    }

    // MARK: Migration & persistence

    private func migrateFromV1() {
        let legacyHost = defaults.string(forKey: Keys.legacyHost)
        let legacyUser = defaults.string(forKey: Keys.legacyUsername)
        let legacyAliases = defaults.dictionary(forKey: Keys.legacyAliases) as? [String: String]
        let legacyPassword = passwordStore.password(forAccount: Keys.legacyKeychainAccount)

        let hasLegacyData = legacyHost != nil
            || legacyUser != nil
            || (legacyAliases?.isEmpty == false)
            || (legacyPassword?.isEmpty == false)

        if hasLegacyData {
            let trimmedHost = legacyHost?.trimmingCharacters(in: .whitespaces) ?? ""
            let host = trimmedHost.isEmpty ? "192.168.100.1" : trimmedHost
            let trimmedUser = legacyUser?.trimmingCharacters(in: .whitespaces) ?? ""
            let username = trimmedUser.isEmpty ? "root" : trimmedUser

            let profile = RouterProfile(
                id: UUID(),
                name: "Previous router",
                host: host,
                username: username,
                lastUsed: Date()
            )
            profiles = [profile]
            activeProfileId = profile.id

            if let legacyAliases, !legacyAliases.isEmpty {
                let normalized = Dictionary(
                    legacyAliases.map { ($0.key.lowercased(), $0.value) },
                    uniquingKeysWith: { _, latest in latest }
                )
                profileAliases[profile.id.uuidString] = normalized
                saveAliases()
            }

            if let legacyPassword, !legacyPassword.isEmpty {
                passwordStore.setPassword(legacyPassword, forAccount: profile.id.uuidString)
                // Only remove the legacy Keychain item once the per-profile copy is confirmed readable.
                if passwordStore.password(forAccount: profile.id.uuidString) == legacyPassword {
                    passwordStore.deletePassword(forAccount: Keys.legacyKeychainAccount)
                }
            }

            saveProfiles()
        }

        defaults.set(true, forKey: Keys.migrated)
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Keys.profiles)
        }
    }

    private func saveActiveProfileId() {
        if let activeProfileId {
            defaults.set(activeProfileId.uuidString, forKey: Keys.activeProfileId)
        } else {
            defaults.removeObject(forKey: Keys.activeProfileId)
        }
    }

    private func saveAliases() {
        defaults.set(profileAliases, forKey: Keys.profileAliases)
    }

    private static func cleanName(_ raw: String, fallbackHost: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let hostTrimmed = fallbackHost.trimmingCharacters(in: .whitespaces)
        return hostTrimmed.isEmpty ? "Router" : hostTrimmed
    }

    private static func cleanUsername(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "root" : trimmed
    }
}
