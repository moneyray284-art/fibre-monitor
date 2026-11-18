import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
private final class ProfileDraftStore: ObservableObject {
    @Published var profileName: String
    @Published var routerName: String
    @Published var profilePhotoData: Data?

    init(profile: RouterProfile?, photoData: Data?) {
        profileName = profile?.name ?? ""
        routerName = profile?.routerDisplayName ?? ""
        profilePhotoData = photoData
    }
}

struct ProfileSheetView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @ObservedObject private var avatarStore: ProfileAvatarStore
    @Environment(\.dismiss) private var dismiss

    @State private var editingProfileID: UUID?
    @StateObject private var draft: ProfileDraftStore
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isShowingPhotos = false
    @State private var isImportingFile = false
    @State private var isConfirmingRemoveProfile = false
    @State private var errorMessage: String?
    @State private var presentationDetent: PresentationDetent = .large

    init(viewModel: MonitorViewModel) {
        self.viewModel = viewModel
        let profile = viewModel.settings.activeProfile
        let avatarStore = ProfileAvatarStore.shared
        _avatarStore = ObservedObject(wrappedValue: avatarStore)
        _editingProfileID = State(initialValue: profile?.id)
        _draft = StateObject(wrappedValue: ProfileDraftStore(
            profile: profile,
            photoData: avatarStore.savedPhotoData(for: profile?.id)
        ))
    }

    private var settings: SettingsStore { viewModel.settings }
    private var editingProfile: RouterProfile? {
        guard let editingProfileID else { return nil }
        return settings.profiles.first { $0.id == editingProfileID }
    }
    private var canSave: Bool {
        editingProfile != nil && !draft.profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        draftAvatarPreview
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
                            if draft.profilePhotoData != nil {
                                Button(role: .destructive) {
                                    removePhoto()
                                } label: {
                                    Label("Remove Photo", systemImage: "person.crop.circle.badge.xmark")
                                }
                            }
                        } label: {
                            Label(draft.profilePhotoData == nil ? "Set Profile Picture" : "Change Profile Picture", systemImage: "photo")
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Profile Name")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("Saved router connection name", text: $draft.profileName)
                            .textContentType(.name)
                            .textInputAutocapitalization(.words)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Router Name")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("Name displayed on Home", text: $draft.routerName)
                            .textInputAutocapitalization(.words)
                    }
                } header: {
                    Text("Profile")
                } footer: {
                    Text("Profile Name identifies this saved connection. Router Name appears on the Home gateway card.")
                }

                if editingProfile != nil {
                    Section("Router Details") {
                        LabeledContent("ONT Model", value: viewModel.displayModelName)
                        LabeledContent("Gateway IP", value: editingProfile?.host ?? "—")
                        LabeledContent("Optical RX", value: opticalRxText)
                        LabeledContent("Last Sync", value: lastSyncText)
                    }

                    Section {
                        Button(role: .destructive) {
                            isConfirmingRemoveProfile = true
                        } label: {
                            HStack {
                                Spacer()
                                Text("Remove Profile")
                                Spacer()
                            }
                        }
                    }
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
            .confirmationDialog(
                "Remove Profile?",
                isPresented: $isConfirmingRemoveProfile,
                titleVisibility: .visible
            ) {
                Button("Remove Profile", role: .destructive, action: removeProfile)
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This removes the saved router connection and its local history from LinkWave.")
            }
            .onAppear { avatarStore.activateProfile(editingProfileID) }
        }
        .presentationDetents([.medium, .large], selection: $presentationDetent)
        .presentationDragIndicator(.visible)
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

    private var draftAvatarPreview: some View {
        Group {
            if let data = draft.profilePhotoData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 28, weight: .medium))
                    .frame(width: 64, height: 64)
            }
        }
        .accessibilityLabel(draft.profilePhotoData == nil ? "Default profile silhouette" : "Profile picture preview")
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
        guard let profile = editingProfile else { return }
        let cleanProfileName = draft.profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanProfileName.isEmpty else { return }
        let cleanRouterName = draft.routerName.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.updateProfileNames(id: profile.id, profileName: cleanProfileName, routerName: cleanRouterName)
        dismiss()
    }

    private func removeProfile() {
        guard let profileID = editingProfileID else { return }
        avatarStore.remove(for: profileID)
        settings.deleteProfile(profileID)
        dismiss()
    }

    private func removePhoto() {
        avatarStore.remove(for: editingProfileID)
        draft.profilePhotoData = nil
    }

    @MainActor
    private func loadImage(from item: PhotosPickerItem) async {
        defer { selectedPhoto = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  UIImage(data: data) != nil else {
                errorMessage = "The selected photo couldn’t be opened."
                return
            }
            persistSelectedImage(data)
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
            guard UIImage(data: data) != nil else {
                errorMessage = "The selected file doesn’t contain a supported image."
                return
            }
            persistSelectedImage(data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistSelectedImage(_ data: Data) {
        do {
            let fittedData = try avatarStore.saveSelectedImageData(data, for: editingProfileID)
            draft.profilePhotoData = fittedData
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
