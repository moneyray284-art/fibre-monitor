import SwiftUI

/// Shown on launch when 2 or more router profiles exist so the user picks the connected router before login.
struct RouterLaunchPickerView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @State private var addingProfile = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(viewModel.settings.profiles) { profile in
                        Button {
                            viewModel.selectRouterAndStart(profile)
                        } label: {
                            RouterProfileRow(
                                profile: profile,
                                isActive: profile.id == viewModel.settings.activeProfile?.id
                            )
                        }
                        .linkWaveText(.primary)
                    }
                } header: {
                    Text("Saved routers")
                } footer: {
                    Text("Choose the router your iPhone is currently connected to. Switching logs out of any previous router session first.")
                }

                Section {
                    Button {
                        addingProfile = true
                    } label: {
                        Label("Add Router", systemImage: "plus.circle")
                    }
                }
            }
            .linkWaveThemedListSurface()
            .navigationTitle("Choose Router")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $addingProfile) {
                RouterProfileEditorView(
                    mode: .add,
                    settings: viewModel.settings
                ) { saved in
                    viewModel.selectRouterAndStart(saved)
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

struct RouterProfileRow: View {
    let profile: RouterProfile
    let isActive: Bool
    @Environment(\.linkWaveThemePalette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.router")
                .font(.title3)
                .foregroundColor(isActive ? palette.textAccent : palette.textSecondary.color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.subheadline.weight(.semibold))
                    if let model = profile.detectedModel, !model.isEmpty {
                        Text(model)
                            .font(.caption2.weight(.medium))
                            .linkWaveText(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text(profile.host)
                        .font(.caption.monospaced())
                        .linkWaveText(.secondary)
                    if let cfg = profile.cfgMode, !cfg.isEmpty {
                        Text("· \(cfg)")
                            .font(.caption2)
                            .linkWaveText(.secondary)
                    }
                }
                if let lastUsed = profile.lastUsed {
                    Text("Last used \(lastUsed.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .linkWaveText(.secondary)
                }
            }

            Spacer()

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(palette.textAccent)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isActive ? "Active router" : "")
    }
}

private enum AddRouterPreset: Hashable {
    case autoDetected
    case telecel
    case mtn
    case standard
}

struct RouterProfileEditorView: View {
    enum Mode: Identifiable {
        case add
        case edit(RouterProfile)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let p): return p.id.uuidString
            }
        }
    }

    let mode: Mode
    @ObservedObject var settings: SettingsStore
    let onSave: (RouterProfile) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var username = "root"
    @State private var password = ""
    @State private var routerType: RouterType = .huaweiONT
    @State private var selectedPreset: AddRouterPreset = .standard
    @State private var autoDetectedProfile: RouterProfile?
    @State private var gatewayForDetection: String?
    @State private var hasUserEditedForm = false

    private var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isHostValid: Bool { HuaweiOntClient.isValidHost(trimmedHost) }
    private var canSave: Bool {
        !trimmedName.isEmpty && isHostValid && !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if case .add = mode {
                    Section("Device / ISP Preset") {
                        Picker("Device / ISP Preset", selection: presetSelection) {
                            if autoDetectedProfile != nil {
                                Text("Auto-Detected").tag(AddRouterPreset.autoDetected)
                            }
                            Text("Telecel Fibre (192.168.100.1)").tag(AddRouterPreset.telecel)
                            Text("MTN Fibre (192.168.2.1)").tag(AddRouterPreset.mtn)
                            Text("Standard Huawei ONT (192.168.100.1)").tag(AddRouterPreset.standard)
                        }
                        .pickerStyle(.menu)
                    }
                }

                Section {
                    Picker("Router Type", selection: routerTypeField) {
                        ForEach(RouterType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    LabeledContent("Profile name") {
                        TextField("Router name", text: nameField)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Router address") {
                        TextField("192.168.100.1", text: hostField)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Username") {
                        TextField("root", text: usernameField)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Password") {
                        SecureField("Required", text: passwordField)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Router login")
                } footer: {
                    if routerType == .generic {
                        Text("Generic router monitoring depends on a compatible router adapter. Huawei-specific controls require Huawei ONT.")
                    } else if !trimmedHost.isEmpty && !isHostValid {
                        Text("Enter a valid IP address or hostname without http:// (for example 192.168.2.1 or 192.168.100.1).")
                            .foregroundColor(.red)
                    } else {
                        Text("The password is stored in this iPhone's Keychain. After several wrong passwords the router locks logins for a few minutes.")
                    }
                }
            }
            .linkWaveThemedListSurface()
            .navigationTitle(isEditing ? "Edit Router" : "Add Router")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
            .task(id: gatewayForDetection) {
                guard case .add = mode, let gateway = gatewayForDetection else { return }
                guard let detected = await RouterAutoDetector.detectProfile(at: gateway),
                      !Task.isCancelled,
                      !hasUserEditedForm else { return }
                autoDetectedProfile = detected
                selectedPreset = .autoDetected
                apply(detected)
            }
            .onAppear {
                switch mode {
                case .add:
                    if name.isEmpty && host.isEmpty {
                        prepareAddRouterForm()
                    }
                case .edit(let profile):
                    name = profile.name
                    host = profile.host
                    username = profile.username
                    routerType = profile.resolvedRouterType
                    password = settings.password(for: profile.id)
                }
            }
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var presetSelection: Binding<AddRouterPreset> {
        Binding(
            get: { selectedPreset },
            set: { preset in
                guard case .add = mode else { return }
                hasUserEditedForm = true
                selectedPreset = preset
                switch preset {
                case .autoDetected:
                    if let autoDetectedProfile { apply(autoDetectedProfile) }
                case .telecel:
                    apply(RouterProfile(name: "Telecel Fibre", host: "192.168.100.1"))
                case .mtn:
                    apply(RouterProfile(name: "MTN Fibre", host: "192.168.2.1"))
                case .standard:
                    apply(RouterProfile(name: "Huawei ONT", host: "192.168.100.1"))
                }
            }
        )
    }

    private var nameField: Binding<String> {
        Binding(get: { name }, set: { name = $0; hasUserEditedForm = true })
    }

    private var hostField: Binding<String> {
        Binding(get: { host }, set: { host = $0; hasUserEditedForm = true })
    }

    private var usernameField: Binding<String> {
        Binding(get: { username }, set: { username = $0; hasUserEditedForm = true })
    }

    private var passwordField: Binding<String> {
        Binding(get: { password }, set: { password = $0; hasUserEditedForm = true })
    }

    private var routerTypeField: Binding<RouterType> {
        Binding(get: { routerType }, set: { routerType = $0; hasUserEditedForm = true })
    }

    private func prepareAddRouterForm() {
        guard let gateway = LocalWiFiAddress.defaultGatewayIPv4() else {
            selectedPreset = .standard
            apply(RouterProfile(name: "Huawei ONT", host: "192.168.100.1"))
            return
        }

        gatewayForDetection = gateway
        if gateway == "192.168.2.1" {
            selectedPreset = .mtn
            apply(RouterProfile(name: "MTN Fibre", host: gateway))
        } else if gateway == "192.168.100.1" {
            selectedPreset = .telecel
            apply(RouterProfile(name: "Telecel Fibre", host: gateway))
        } else {
            selectedPreset = .standard
            apply(RouterProfile(name: "Huawei ONT", host: gateway))
        }
        hasUserEditedForm = false
    }

    private func apply(_ profile: RouterProfile) {
        name = profile.name
        host = profile.host
        username = profile.username
        password = ""
        routerType = profile.resolvedRouterType
    }

    private func save() {
        switch mode {
        case .add:
            let profile = RouterProfile(
                name: trimmedName,
                host: trimmedHost,
                username: username,
                detectedModel: selectedPreset == .autoDetected ? autoDetectedProfile?.detectedModel : nil,
                routerType: routerType
            )
            let saved = settings.addProfile(profile, password: password, select: true)
            onSave(saved)
        case .edit(var existing):
            existing.name = trimmedName
            existing.host = trimmedHost
            existing.username = username
            existing.routerType = routerType
            settings.updateProfile(existing, password: password)
            onSave(existing)
        }
        dismiss()
    }
}
