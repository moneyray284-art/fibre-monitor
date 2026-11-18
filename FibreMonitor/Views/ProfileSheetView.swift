import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ProfileSheetView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @ObservedObject private var avatarStore = ProfileAvatarStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var profileName: String
    @State private var routerName: String
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isShowingPhotos = false
    @State private var isImportingFile = false
    @State private var errorMessage: String?

    init(viewModel: MonitorViewModel) {
        self.viewModel = viewModel
        let profile = viewModel.settings.activeProfile
        _profileName = State(initialValue: profile?.name ?? "")
        _routerName = State(initialValue: profile?.routerDisplayName ?? "")
    }

    private var settings: SettingsStore { viewModel.settings }
    private var canSave: Bool { settings.activeProfile != nil && !profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        ProfileAvatarView(size: 32)
                        Menu {
                            Button {
                                isShowingPhotos = true
                            } label: {
                                Label("Choose from Photos", systemImage: "photo")
                            }
                            Button {
                                isImportingFile = true
                            } label: {
                                Label("Choose from Files", systemImage: "folder")
                            }
                            if avatarStore.image != nil {
                                Button(role: .destructive) {
                                    avatarStore.remove()
                                } label: {
                                    Label("Remove Photo", systemImage: "person.crop.circle.badge.xmark")
                                }
                            }
                        } label: {
                            Label(avatarStore.image == nil ? "Set Profile Picture" : "Change Profile Picture", systemImage: "photo")
                        }
                    }

                    TextField("Profile name", text: $profileName)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)

                    TextField("Router name", text: $routerName)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("Profile")
                } footer: {
                    Text("The profile name identifies this saved router connection. The router name appears on Home.")
                }

                Section("Router Details") {
                    LabeledContent("ONT Model", value: viewModel.displayModelName)
                    LabeledContent("Gateway IP", value: settings.activeProfile?.host ?? "—")
                    LabeledContent("Optical RX", value: opticalRxText)
                    LabeledContent("Last Sync", value: lastSyncText)
                }
            }
            .linkWaveThemedListSurface()
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .photosPicker(isPresented: $isShowingPhotos, selection: $selectedPhoto, matching: .images)
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
            onCompletion: { result in
                if case .success(let urls) = result, let url = urls.first {
                    importImage(from: url)
                } else if case .failure(let error) = result {
                    errorMessage = error.localizedDescription
                }
            }
        )
        .onChange(of: selectedPhoto) { item in
            guard let item else { return }
            Task { await loadImage(from: item) }
        }
        .onChange(of: settings.activeProfileId) { _ in
            profileName = settings.activeProfile?.name ?? ""
            routerName = settings.activeProfile?.routerDisplayName ?? ""
        }
        .alert(
            "Couldn’t Update Profile Photo",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Please choose another image.")
        }
    }

    private var opticalRxText: String {
        guard let rxPower = viewModel.optical.rxPowerDbm else { return "—" }
        return String(format: "%.2f dBm", rxPower)
    }

    private var lastSyncText: String {
        guard let date = viewModel.lastUpdate else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func save() {
        guard let profile = settings.activeProfile else { return }
        let cleanProfileName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanProfileName.isEmpty else { return }
        let cleanRouterName = routerName.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.updateProfileNames(id: profile.id, profileName: cleanProfileName, routerName: cleanRouterName)
        dismiss()
    }

    @MainActor
    private func loadImage(from item: PhotosPickerItem) async {
        defer { selectedPhoto = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                errorMessage = "The selected photo couldn’t be opened."
                return
            }
            try avatarStore.save(image)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importImage(from url: URL) {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url)
            guard let image = UIImage(data: data) else {
                errorMessage = "The selected file doesn’t contain a supported image."
                return
            }
            try avatarStore.save(image)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
