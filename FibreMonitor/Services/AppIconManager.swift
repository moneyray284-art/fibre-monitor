import Combine
import UIKit

@MainActor
public final class AppIconManager: ObservableObject {
    public static let shared = AppIconManager()

    @Published public private(set) var activeIconName: String?
    @Published public var errorMessage: String?

    private var requestedIconName: String?
    private var hasPendingIconRequest = false

    public var supportsAlternateIcons: Bool {
        UIApplication.shared.supportsAlternateIcons
    }

    private init() {
        activeIconName = UIApplication.shared.alternateIconName
    }

    public func apply(_ choice: AppIconChoice, logoColor: AppLogoColorChoice) {
        let iconName = choice.alternateIconName(logoColor: logoColor)
        guard UIApplication.shared.alternateIconName != iconName else {
            activeIconName = UIApplication.shared.alternateIconName
            return
        }
        if hasPendingIconRequest && requestedIconName == iconName {
            activeIconName = UIApplication.shared.alternateIconName
            return
        }
        guard supportsAlternateIcons else {
            errorMessage = "This iOS version doesn't support changing app icons."
            return
        }

        errorMessage = nil
        requestedIconName = iconName
        hasPendingIconRequest = true
        UIApplication.shared.setAlternateIconName(iconName) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if self.hasPendingIconRequest && self.requestedIconName == iconName {
                    self.requestedIconName = nil
                    self.hasPendingIconRequest = false
                }
                self.activeIconName = UIApplication.shared.alternateIconName
                if let error {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
