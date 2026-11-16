import UIKit

@MainActor
public enum AppIconManager {
    private static var requestedIconName: String?

    public static func apply(_ choice: AppIconChoice) {
        let iconName = choice.alternateIconName
        guard UIApplication.shared.supportsAlternateIcons,
              UIApplication.shared.alternateIconName != iconName,
              requestedIconName != iconName else { return }

        requestedIconName = iconName
        UIApplication.shared.setAlternateIconName(iconName) { _ in
            Task { @MainActor in
                if requestedIconName == iconName { requestedIconName = nil }
            }
        }
    }
}
