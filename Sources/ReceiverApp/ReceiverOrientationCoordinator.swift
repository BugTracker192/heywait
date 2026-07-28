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
    private var requestedGeometryOrientations: UIInterfaceOrientationMask = .portrait
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
            self.request(
                supported: self.supportedOrientations,
                geometry: self.requestedGeometryOrientations,
                force: true
            )
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
        request(supported: .portrait, geometry: .portrait)
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

        // The app must support both sides so UIKit never rejects a landscape
        // transition. The exact side is requested separately from the
        // ReplayKit orientation metadata.
        return .landscape
    }

    private func applyCurrentGeometry() {
        let supported = Self.interfaceOrientations(
            encodedWidth: encodedWidth,
            encodedHeight: encodedHeight,
            videoOrientation: videoOrientation
        )
        request(
            supported: supported,
            geometry: Self.geometryOrientations(
                supported: supported,
                videoOrientation: videoOrientation
            )
        )
    }

    static func geometryOrientations(
        supported: UIInterfaceOrientationMask,
        videoOrientation: UInt32
    ) -> UIInterfaceOrientationMask {
        guard supported == .landscape else { return .portrait }
        switch videoOrientation {
        case 5, 6:
            return .landscapeLeft
        case 7, 8:
            return .landscapeRight
        default:
            return .landscape
        }
    }

    private func request(
        supported: UIInterfaceOrientationMask,
        geometry: UIInterfaceOrientationMask,
        force: Bool = false
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard force
            || supportedOrientations != supported
            || requestedGeometryOrientations != geometry else {
            return
        }
        supportedOrientations = supported
        requestedGeometryOrientations = geometry

        guard let scene = activeWindowScene() else { return }
        let rootViewController = scene.windows
            .first(where: \.isKeyWindow)?
            .rootViewController

        if #available(iOS 16.0, *) {
            rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(
                .iOS(interfaceOrientations: geometry)
            ) { _ in
                // If the exact landscape side is temporarily unavailable,
                // keep the app rotatable instead of leaving it in portrait.
                guard supported == .landscape, geometry != .landscape else { return }
                DispatchQueue.main.async {
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
                }
            }
        } else {
            let deviceOrientation: UIDeviceOrientation
            if geometry == .portrait {
                deviceOrientation = .portrait
            } else if geometry == .landscapeLeft {
                deviceOrientation = .landscapeRight
            } else if geometry == .landscapeRight {
                deviceOrientation = .landscapeLeft
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
