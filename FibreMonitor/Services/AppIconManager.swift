import Combine
import UIKit

@MainActor
public final class AppIconManager: ObservableObject {
    public static let shared = AppIconManager()

    @Published public private(set) var activeIconName: String?
    @Published public var errorMessage: String?

    private var requestedIconName: String?

    public var supportsAlternateIcons: Bool {
        UIApplication.shared.supportsAlternateIcons
    }

    private init() {
        activeIconName = UIApplication.shared.alternateIconName
    }

    public func apply(_ choice: AppIconChoice) {
        let iconName = choice.alternateIconName
        guard UIApplication.shared.alternateIconName != iconName,
              requestedIconName != iconName else {
            activeIconName = UIApplication.shared.alternateIconName
            return
        }
        guard supportsAlternateIcons else {
            errorMessage = "This iOS version doesn't support changing app icons."
            return
        }

        errorMessage = nil
        requestedIconName = iconName
        UIApplication.shared.setAlternateIconName(iconName) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if self.requestedIconName == iconName {
                    self.requestedIconName = nil
                }
                self.activeIconName = UIApplication.shared.alternateIconName
                if let error {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
