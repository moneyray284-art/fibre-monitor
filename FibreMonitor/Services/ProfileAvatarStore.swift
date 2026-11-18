import SwiftUI
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
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: size, height: size)
            }
        }
        .accessibilityLabel(store.image == nil ? "Profile, no photo selected" : "Profile photo")
    }
}

public struct ProfileAvatarPickerButton: View {
    let viewModel: MonitorViewModel
    private let size: CGFloat
    @State private var isShowingProfile = false

    public init(viewModel: MonitorViewModel, size: CGFloat = 32) {
        self.viewModel = viewModel
        self.size = size
    }

    public var body: some View {
        Button {
            isShowingProfile = true
        } label: {
            ProfileAvatarView(size: size)
        }
        .buttonStyle(.plain)
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .accessibilityLabel("Open Profile")
        .sheet(isPresented: $isShowingProfile) {
            ProfileSheetView(viewModel: viewModel)
        }
    }
}
