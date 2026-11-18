import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

@MainActor
public final class ProfileAvatarStore: ObservableObject {
    public static let shared = ProfileAvatarStore()

    @Published public private(set) var image: UIImage?

    private let defaults = UserDefaults.standard
    private let storageKey = "linkwave_profile_avatar_path"
    private let filename = "LinkWaveProfileAvatar.jpg"

    private init() {
        guard let path = defaults.string(forKey: storageKey),
              let savedImage = UIImage(contentsOfFile: path) else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        image = savedImage
    }

    public func save(_ source: UIImage) throws {
        guard let thumbnail = Self.squareThumbnail(source),
              let jpegData = thumbnail.jpegData(compressionQuality: 0.84) else {
            throw ProfileAvatarStoreError.couldNotEncodeImage
        }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destination = documents.appendingPathComponent(filename)
        try jpegData.write(to: destination, options: .atomic)
        defaults.set(destination.path, forKey: storageKey)
        image = UIImage(data: jpegData)
    }

    public func remove() {
        if let path = defaults.string(forKey: storageKey) {
            try? FileManager.default.removeItem(atPath: path)
        }
        defaults.removeObject(forKey: storageKey)
        image = nil
    }

    private static func squareThumbnail(_ image: UIImage) -> UIImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }

        let side: CGFloat = 256
        let scale = max(side / image.size.width, side / image.size.height)
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let drawOrigin = CGPoint(x: (side - drawSize.width) / 2, y: (side - drawSize.height) / 2)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))

        return renderer.image { _ in
            image.draw(in: CGRect(origin: drawOrigin, size: drawSize))
        }
    }
}

public enum ProfileAvatarStoreError: LocalizedError {
    case couldNotEncodeImage

    public var errorDescription: String? {
        switch self {
        case .couldNotEncodeImage:
            return "This image couldn't be prepared for your profile."
        }
    }
}

public struct ProfileAvatarView: View {
    @ObservedObject private var store: ProfileAvatarStore
    @Environment(\.linkWaveLogoColor) private var logoColor
    private let size: CGFloat

    public init(size: CGFloat = 52) {
        self.size = size
        self._store = ObservedObject(wrappedValue: .shared)
    }

    public var body: some View {
        Group {
            if let image = store.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text("LW")
                    .font(.system(size: size * 0.28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        LinearGradient(
                            colors: [logoColor, logoColor.opacity(0.72)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 1))
        .accessibilityLabel(store.image == nil ? "LinkWave profile picture, default LW initials" : "LinkWave profile picture")
    }
}

public struct ProfileAvatarPickerButton: View {
    @ObservedObject private var store = ProfileAvatarStore.shared
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isShowingPhotos = false
    @State private var isImportingFile = false
    @State private var errorMessage: String?

    private let size: CGFloat

    public init(size: CGFloat = 38) {
        self.size = size
    }

    public var body: some View {
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
            if store.image != nil {
                Button(role: .destructive) {
                    store.remove()
                } label: {
                    Label("Remove Photo", systemImage: "person.crop.circle.badge.xmark")
                }
            }
        } label: {
            ProfileAvatarView(size: size)
                .frame(width: size, height: size)
                .padding(3)
                .modifier(LiquidGlassToolbarCircleModifier())
                .frame(width: size + 6, height: size + 6)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel("Profile photo options")
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

    @MainActor
    private func loadImage(from item: PhotosPickerItem) async {
        defer { selectedPhoto = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                errorMessage = "The selected photo couldn’t be opened."
                return
            }
            try store.save(image)
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
            try store.save(image)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
