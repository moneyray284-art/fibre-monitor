import SwiftUI
import UIKit

@MainActor
public final class ProfileAvatarStore: ObservableObject {
    public static let shared = ProfileAvatarStore()

    @Published public private(set) var image: UIImage?

    private let defaults = UserDefaults.standard
    private let pathsKey = "linkwave_profile_avatar_paths"
    private let legacyStorageKey = "linkwave_profile_avatar_path"
    private var activeProfileID: UUID?
    private var imageCache: [String: UIImage] = [:]

    private init() { }

    public func activateProfile(_ profileID: UUID?) {
        migrateLegacyImageIfNeeded(for: profileID)
        activeProfileID = profileID
        image = image(for: profileID)
    }

    public func image(for profileID: UUID?) -> UIImage? {
        migrateLegacyImageIfNeeded(for: profileID)
        let key = scopeKey(for: profileID)
        if let cached = imageCache[key] { return cached }
        guard let path = savedPath(for: key),
              let savedImage = UIImage(contentsOfFile: path) else { return nil }
        imageCache[key] = savedImage
        return savedImage
    }

    public func savedPhotoData(for profileID: UUID?) -> Data? {
        migrateLegacyImageIfNeeded(for: profileID)
        guard let path = savedPath(for: scopeKey(for: profileID)) else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Normalizes orientation, center-crops with aspect fill, and saves the 512×512 JPEG immediately.
    /// Returns the same fitted bytes for the profile sheet's preview.
    @discardableResult
    public func saveSelectedImageData(_ sourceData: Data, for profileID: UUID?) throws -> Data {
        guard let source = UIImage(data: sourceData),
              let normalized = Self.normalizedImage(source),
              let fittedJPEG = Self.aspectFillJPEG(normalized) else {
            throw ProfileAvatarStoreError.couldNotEncodeImage
        }

        try saveJPEGData(fittedJPEG, for: profileID)
        return fittedJPEG
    }

    public func saveJPEGData(_ jpegData: Data?, for profileID: UUID?) throws {
        guard let jpegData else {
            remove(for: profileID)
            return
        }
        guard let savedImage = UIImage(data: jpegData) else {
            throw ProfileAvatarStoreError.couldNotEncodeImage
        }

        migrateLegacyImageIfNeeded(for: profileID)
        let key = scopeKey(for: profileID)
        let supportDirectory = try Self.applicationSupportDirectory()
        let destination = supportDirectory.appendingPathComponent("LinkWaveProfileAvatar-\(key).jpg", isDirectory: false)
        try jpegData.write(to: destination, options: .atomic)

        var paths = storedPaths
        paths[key] = destination.path
        defaults.set(paths, forKey: pathsKey)
        imageCache[key] = savedImage
        if activeProfileID == profileID { image = savedImage }
    }

    public func remove(for profileID: UUID?) {
        migrateLegacyImageIfNeeded(for: profileID)
        let key = scopeKey(for: profileID)
        var paths = storedPaths
        if let path = paths.removeValue(forKey: key) {
            try? FileManager.default.removeItem(atPath: path)
        }
        if let expectedURL = try? Self.avatarURL(for: key) {
            try? FileManager.default.removeItem(at: expectedURL)
        }
        defaults.set(paths, forKey: pathsKey)
        imageCache.removeValue(forKey: key)
        if activeProfileID == profileID { image = nil }
    }

    private var storedPaths: [String: String] {
        defaults.dictionary(forKey: pathsKey) as? [String: String] ?? [:]
    }

    private func scopeKey(for profileID: UUID?) -> String {
        profileID?.uuidString.lowercased() ?? "unconfigured"
    }

    private func savedPath(for key: String) -> String? {
        storedPaths[key]
    }

    private func migrateLegacyImageIfNeeded(for profileID: UUID?) {
        let key = scopeKey(for: profileID)
        var paths = storedPaths
        guard paths[key] == nil else { return }

        // Move the existing single-avatar install to the first profile that uses the new store.
        if let legacyPath = defaults.string(forKey: legacyStorageKey) {
            paths[key] = legacyPath
            defaults.set(paths, forKey: pathsKey)
            defaults.removeObject(forKey: legacyStorageKey)
            if let legacyImage = UIImage(contentsOfFile: legacyPath) {
                imageCache[key] = legacyImage
            }
            return
        }

        // If an avatar was chosen before a router was configured, attach it to the first saved router.
        guard profileID != nil,
              let unconfiguredPath = paths.removeValue(forKey: "unconfigured") else { return }
        paths[key] = unconfiguredPath
        defaults.set(paths, forKey: pathsKey)
        if let unconfiguredImage = imageCache.removeValue(forKey: "unconfigured") {
            imageCache[key] = unconfiguredImage
        }
    }

    private static func applicationSupportDirectory() throws -> URL {
        let manager = FileManager.default
        guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ProfileAvatarStoreError.couldNotSaveImage
        }
        let directory = support.appendingPathComponent("LinkWave", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func avatarURL(for key: String) throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("LinkWaveProfileAvatar-\(key).jpg", isDirectory: false)
    }

    private static func normalizedImage(_ image: UIImage) -> UIImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        guard image.imageOrientation != .up else { return image }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private static func aspectFillJPEG(_ image: UIImage) -> Data? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }

        let side: CGFloat = 512
        let scale = max(side / image.size.width, side / image.size.height)
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let drawRect = CGRect(
            x: (side - drawSize.width) / 2,
            y: (side - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let fitted = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            image.draw(in: drawRect)
        }
        return fitted.jpegData(compressionQuality: 0.88)
    }
}

public enum ProfileAvatarStoreError: LocalizedError {
    case couldNotEncodeImage
    case couldNotSaveImage

    public var errorDescription: String? {
        switch self {
        case .couldNotEncodeImage:
            return "This image couldn't be prepared for your profile."
        case .couldNotSaveImage:
            return "The profile picture couldn't be saved on this device."
        }
    }
}

public struct ProfileAvatarView: View {
    @ObservedObject private var store: ProfileAvatarStore
    private let profileID: UUID?
    private let size: CGFloat
    private let silhouetteSize: CGFloat
    private let cornerRadius: CGFloat

    public init(
        size: CGFloat = 40,
        silhouetteSize: CGFloat = 25,
        cornerRadius: CGFloat = 12,
        profileID: UUID? = nil
    ) {
        self.size = size
        self.silhouetteSize = silhouetteSize
        self.cornerRadius = cornerRadius
        self.profileID = profileID
        self._store = ObservedObject(wrappedValue: .shared)
    }

    public var body: some View {
        Group {
            if let image = store.image(for: profileID) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: silhouetteSize, weight: .medium))
                    .frame(width: size, height: size)
            }
        }
        .onAppear { store.activateProfile(profileID) }
        .onChange(of: profileID) { store.activateProfile($0) }
        .accessibilityLabel(store.image(for: profileID) == nil ? "Profile, no photo selected" : "Profile photo")
    }
}

public struct ProfileAvatarPickerButton: View {
    let viewModel: MonitorViewModel
    private let size: CGFloat
    @State private var isShowingProfile = false
    @State private var sheetSessionID = UUID()

    public init(viewModel: MonitorViewModel, size: CGFloat = 40) {
        self.viewModel = viewModel
        self.size = size
    }

    private var activeProfileID: UUID? { viewModel.settings.activeProfile?.id }

    public var body: some View {
        Button {
            sheetSessionID = UUID()
            isShowingProfile = true
        } label: {
            ProfileAvatarView(size: size, profileID: activeProfileID)
        }
        .buttonStyle(.plain)
        .frame(width: size, height: size)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("Open Profile")
        .sheet(isPresented: $isShowingProfile) {
            ProfileSheetView(viewModel: viewModel)
                .id(sheetSessionID)
        }
    }
}
