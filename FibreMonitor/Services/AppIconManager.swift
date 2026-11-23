import Combine
import UIKit

@MainActor
public final class AppIconManager: ObservableObject {
    public static let shared = AppIconManager()

    private struct IconRequest {
        let id = UUID()
        let name: String?
    }

    @Published public private(set) var activeIconName: String?
    @Published public var errorMessage: String?

    private var inFlightRequest: IconRequest?
    private var queuedRequest: IconRequest?

    public var supportsAlternateIcons: Bool {
        UIApplication.shared.supportsAlternateIcons
    }

    private init() {
        activeIconName = UIApplication.shared.alternateIconName
    }

    public func apply(_ choice: AppIconChoice, logoColor: AppLogoColorChoice) {
        let iconName = choice.alternateIconName(logoColor: logoColor)
        if let inFlightRequest {
            // UIKit presents a confirmation alert for each icon change. Serialize
            // requests and keep only the latest selection while one alert is open.
            if inFlightRequest.name == iconName {
                queuedRequest = nil
            } else {
                queuedRequest = IconRequest(name: iconName)
            }
            return
        }

        guard UIApplication.shared.alternateIconName != iconName else {
            activeIconName = UIApplication.shared.alternateIconName
            errorMessage = nil
            return
        }

        start(IconRequest(name: iconName))
    }

    private func start(_ request: IconRequest) {
        guard UIApplication.shared.alternateIconName != request.name else {
            activeIconName = UIApplication.shared.alternateIconName
            errorMessage = nil
            return
        }
        guard supportsAlternateIcons else {
            errorMessage = "This iOS version doesn't support changing app icons."
            return
        }

        errorMessage = nil
        inFlightRequest = request
        UIApplication.shared.setAlternateIconName(request.name) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                guard self.inFlightRequest?.id == request.id else { return }

                self.inFlightRequest = nil
                self.activeIconName = UIApplication.shared.alternateIconName
                let queuedRequest = self.queuedRequest
                self.queuedRequest = nil

                if let queuedRequest {
                    if queuedRequest.name != self.activeIconName {
                        self.start(queuedRequest)
                    } else {
                        self.errorMessage = nil
                    }
                } else if let error {
                    self.errorMessage = error.localizedDescription
                } else {
                    self.errorMessage = nil
                }
            }
        }
    }
}
