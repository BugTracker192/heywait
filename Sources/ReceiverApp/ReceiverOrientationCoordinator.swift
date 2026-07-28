import Dispatch
import UIKit

final class ReceiverAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        ReceiverOrientationCoordinator.shared.supportedOrientations
    }
}

final class ReceiverOrientationCoordinator {
    static let shared = ReceiverOrientationCoordinator()

    private(set) var supportedOrientations: UIInterfaceOrientationMask = .portrait
    private var encodedWidth: Int32 = 0
    private var encodedHeight: Int32 = 0
    private var videoOrientation: UInt32 = 1
    private var didBecomeActiveObserver: NSObjectProtocol?

    private init() {
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.request(self.supportedOrientations, force: true)
        }
    }

    func update(configuration: VideoConfiguration) {
        encodedWidth = configuration.width
        encodedHeight = configuration.height
        videoOrientation = configuration.orientation
        applyCurrentGeometry()
    }

    func update(videoOrientation: UInt32) {
        self.videoOrientation = videoOrientation
        applyCurrentGeometry()
    }

    func reset() {
        encodedWidth = 0
        encodedHeight = 0
        videoOrientation = 1
        request(.portrait)
    }

    static func interfaceOrientations(
        encodedWidth: Int32,
        encodedHeight: Int32,
        videoOrientation: UInt32
    ) -> UIInterfaceOrientationMask {
        guard encodedWidth > 0, encodedHeight > 0 else { return .portrait }

        let isQuarterTurn = (5...8).contains(videoOrientation)
        let displayWidth = isQuarterTurn ? encodedHeight : encodedWidth
        let displayHeight = isQuarterTurn ? encodedWidth : encodedHeight
        guard displayWidth > displayHeight else { return .portrait }

        // ReplayKit uses CGImagePropertyOrientation raw values. A `.right`
        // image (6) needs a clockwise correction, which corresponds to a
        // UIKit landscape-left interface; `.left` (8) is the opposite side.
        // Requesting the generic `.landscape` mask lets iOS choose either
        // side and can put the viewer 180 degrees opposite the sender.
        switch videoOrientation {
        case 5, 6:
            return .landscapeLeft
        case 7, 8:
            return .landscapeRight
        default:
            return .landscape
        }
    }

    private func applyCurrentGeometry() {
        request(Self.interfaceOrientations(
            encodedWidth: encodedWidth,
            encodedHeight: encodedHeight,
            videoOrientation: videoOrientation
        ))
    }

    private func request(
        _ orientations: UIInterfaceOrientationMask,
        force: Bool = false
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard force || supportedOrientations != orientations else { return }
        supportedOrientations = orientations

        guard let scene = activeWindowScene() else { return }
        let rootViewController = scene.windows
            .first(where: \.isKeyWindow)?
            .rootViewController

        if #available(iOS 16.0, *) {
            rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(
                .iOS(interfaceOrientations: orientations)
            ) { _ in
                // Becoming active or receiving another video geometry update retries.
            }
        } else {
            let deviceOrientation: UIDeviceOrientation
            if orientations == .portrait {
                deviceOrientation = .portrait
            } else if UIDevice.current.orientation.isLandscape {
                deviceOrientation = UIDevice.current.orientation
            } else {
                deviceOrientation = .landscapeRight
            }
            UIDevice.current.setValue(deviceOrientation.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    private func activeWindowScene() -> UIWindowScene? {
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return windowScenes.first(where: { $0.activationState == .foregroundActive })
            ?? windowScenes.first
    }
}
