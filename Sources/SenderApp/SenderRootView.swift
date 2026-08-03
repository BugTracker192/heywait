import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ReplayKit
import SwiftUI
import UIKit

final class SenderViewModel: ObservableObject {
    @Published var deliveryMode: DeliveryMode
    @Published var selectedServiceName: String
    @Published var pairingCode: String
    @Published var quality: StreamQuality
    @Published var browserAccessKey: String
    @Published var orientationMode: StreamOrientationMode
    @Published var rotationDirection: StreamRotationDirection
    @Published var framingMode: ViewerFramingMode
    @Published private(set) var didSave: Bool

    let discovery = ReceiverDiscovery()
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let saved = SenderConfigurationStore.shared.load()
        deliveryMode = saved.deliveryMode
        selectedServiceName = saved.receiverServiceName
        pairingCode = PairingSecret.format(saved.pairingCode)
        quality = saved.quality
        browserAccessKey = saved.browserAccessKey
        orientationMode = saved.orientationMode
        rotationDirection = saved.rotationDirection
        framingMode = saved.framingMode
        didSave = saved.isReady

        discovery.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var configuration: SenderConfiguration {
        SenderConfiguration(
            deliveryMode: deliveryMode,
            receiverServiceName: selectedServiceName,
            pairingCode: pairingCode,
            quality: quality,
            browserAccessKey: browserAccessKey,
            orientationMode: orientationMode,
            rotationDirection: rotationDirection,
            framingMode: framingMode
        )
    }

    var browserURL: URL? {
        LocalBrowserLink.currentURL(accessKey: browserAccessKey)
    }

    var isReady: Bool {
        configuration.isReady && (deliveryMode != .browser || browserURL != nil)
    }

    func select(_ receiver: DiscoveredReceiver) {
        selectedServiceName = receiver.name
        didSave = false
    }

    func markDirty() {
        let saved = SenderConfigurationStore.shared.load()
        didSave =
            deliveryMode == saved.deliveryMode
            && selectedServiceName == saved.receiverServiceName
            && PairingSecret.normalize(pairingCode) == PairingSecret.normalize(saved.pairingCode)
            && quality == saved.quality
            && PairingSecret.normalize(browserAccessKey) == PairingSecret.normalize(saved.browserAccessKey)
            && orientationMode == saved.orientationMode
            && rotationDirection == saved.rotationDirection
            && framingMode == saved.framingMode
    }

    func regenerateBrowserLink() {
        browserAccessKey = PairingSecret.normalize(PairingSecret.generate())
        saveBrowserConfigurationIfPossible()
    }

    func saveBrowserConfigurationIfPossible() {
        guard deliveryMode == .browser, isReady else {
            markDirty()
            return
        }
        save()
    }

    func save() {
        guard isReady else { return }
        pairingCode = PairingSecret.format(pairingCode)
        browserAccessKey = PairingSecret.normalize(browserAccessKey)
        SenderConfigurationStore.shared.save(configuration)
        didSave = true
    }
}

struct SenderRootView: View {
    @StateObject private var model = SenderViewModel()

    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.04, green: 0.07, blue: 0.13), Color(red: 0.03, green: 0.18, blue: 0.22)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        header
                        modeCard
                        if model.deliveryMode == .nativeReceiver {
                            receiverCard
                            pairingCard
                        } else {
                            browserCard
                        }
                        qualityCard
                        orientationCard
                        if model.deliveryMode == .browser {
                            framingCard
                        }
                        startCard
                        privacyNote
                    }
                    .padding(20)
                }
            }
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
        .onAppear {
            if model.deliveryMode == .nativeReceiver {
                model.discovery.start()
            }
        }
        .onDisappear {
            model.discovery.stop()
        }
        .onChange(of: model.deliveryMode) { mode in
            if mode == .nativeReceiver {
                model.markDirty()
                model.discovery.start()
            } else {
                model.discovery.stop()
                model.saveBrowserConfigurationIfPossible()
            }
        }
        .onChange(of: model.pairingCode) { _ in model.markDirty() }
        .onChange(of: model.quality) { _ in model.saveBrowserConfigurationIfPossible() }
        .onChange(of: model.orientationMode) { _ in model.saveBrowserConfigurationIfPossible() }
        .onChange(of: model.rotationDirection) { _ in model.saveBrowserConfigurationIfPossible() }
        .onChange(of: model.framingMode) { _ in model.saveBrowserConfigurationIfPossible() }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Color.cyan)
            Text("Screen Share")
                .font(.largeTitle.bold())
            Text("Secure, low-latency mirroring on your local network")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 14)
    }

    private var modeCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Viewing method", systemImage: "rectangle.connected.to.line.below")
                    .font(.headline)
                Picker("Viewing method", selection: $model.deliveryMode) {
                    ForEach(DeliveryMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(
                    model.deliveryMode == .nativeReceiver
                        ? "Lowest latency and highest frame rate."
                        : "No receiver app required. Open a private local link in a browser."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var receiverCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Label("1. Choose receiver", systemImage: "iphone.gen3.radiowaves.left.and.right")
                    .font(.headline)
                Text(model.discovery.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.discovery.receivers.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching nearby…")
                        Spacer()
                        Button {
                            model.discovery.retryNow()
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.bordered)
                        .tint(.cyan)
                        .accessibilityLabel("Retry receiver discovery")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                } else {
                    ForEach(model.discovery.receivers) { receiver in
                        Button {
                            model.select(receiver)
                        } label: {
                            HStack {
                                Image(systemName: "iphone")
                                Text(displayName(receiver.name))
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: model.selectedServiceName == receiver.name ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.selectedServiceName == receiver.name ? Color.cyan : Color.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 5)
                    }
                }
            }
        }
    }

    private var pairingCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Label("2. Enter pairing code", systemImage: "lock.shield")
                    .font(.headline)
                TextField("XXXX-XXXX-XXXX-XXXX", text: $model.pairingCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled(true)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .padding(13)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                Text("The code is shown on the receiving iPhone. It becomes the end-to-end encryption key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var browserCard: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                Label("Browser link", systemImage: "qrcode")
                    .font(.headline)

                if let url = model.browserURL {
                    HStack(alignment: .top, spacing: 16) {
                        if let image = BrowserQRCode.image(for: url.absoluteString) {
                            Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 136, height: 136)
                                .padding(8)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text(url.absoluteString)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                            Button {
                                UIPasteboard.general.url = url
                            } label: {
                                Label("Copy link", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                            .tint(.cyan)
                        }
                    }

                    Button {
                        model.regenerateBrowserLink()
                    } label: {
                        Label("Generate a new private link", systemImage: "arrow.clockwise")
                    }
                    .font(.caption)

                    Text(
                        "Save Browser mode and start the broadcast first. Once the iOS sheet says it is live, scan this QR or open the link. Add it to the Home Screen with Open as Web App enabled for the fullscreen viewer."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Label(
                        "Connect the sender to Wi-Fi to create its local browser link.",
                        systemImage: "wifi.exclamationmark"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var qualityCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Stream quality", systemImage: "speedometer")
                    .font(.headline)
                Picker("Stream quality", selection: $model.quality) {
                    ForEach(StreamQuality.allCases, id: \.self) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .pickerStyle(.segmented)
                Text(
                    model.deliveryMode == .browser
                        ? (
                            model.quality == .dataSaver
                                ? "60 FPS low-resolution target for the smoothest delivery."
                                : "60 FPS hardware H.264 target with automatic JPEG fallback."
                        )
                        : (
                            model.quality == .dataSaver
                                ? "60 FPS low-resolution target for the smoothest delivery."
                                : "60 FPS target on supported sender hardware."
                        )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var startCard: some View {
        card {
            VStack(spacing: 14) {
                Button {
                    model.save()
                } label: {
                    Label(
                        model.didSave
                            ? (model.deliveryMode == .browser ? "Browser link saved" : "Receiver saved")
                            : (model.deliveryMode == .browser ? "Save browser mode" : "Save receiver"),
                        systemImage: model.didSave ? "checkmark" : "link"
                    )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(!model.isReady)

                Divider()

                let broadcastEnabled = model.didSave && model.isReady
                ZStack {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Color.cyan.opacity(0.14))
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(Color.cyan)
                        }
                        .frame(width: 58, height: 58)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Start sharing")
                                .font(.headline)
                            Text(
                                broadcastEnabled
                                    ? "Tap anywhere here, then confirm once in the iOS sheet."
                                    : (
                                        model.deliveryMode == .browser
                                            ? "Save the browser link to enable broadcasting."
                                            : "Choose and save a receiver to enable broadcasting."
                                    )
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    if broadcastEnabled {
                        BroadcastPicker {}
                            .frame(maxWidth: .infinity, minHeight: 58)
                            .accessibilityLabel("Start screen sharing")
                    }
                }
                .contentShape(Rectangle())
                .opacity(broadcastEnabled ? 1 : 0.35)
            }
        }
    }

    private var privacyNote: some View {
        VStack(spacing: 8) {
            Label(
                "Screen Share never uses a cloud relay. iOS displays its standard capture indicator while your screen is being shared.",
                systemImage: "hand.raised.fill"
            )
            Text(buildLabel)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
            if let orientationDiagnostic {
                Text(orientationDiagnostic)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }

    private var orientationCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Stream orientation", systemImage: "rectangle.landscape.rotate")
                    .font(.headline)
                Picker("Stream orientation", selection: $model.orientationMode) {
                    ForEach(StreamOrientationMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if model.orientationMode != .automatic {
                    Picker("Rotation direction", selection: $model.rotationDirection) {
                        ForEach(StreamRotationDirection.allCases, id: \.self) { direction in
                            Text(direction.title).tag(direction)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Text(
                    orientationDescription
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var orientationDescription: String {
        switch model.orientationMode {
        case .automatic:
            return "The receiver follows portrait and landscape changes automatically."
        case .landscape:
            return "Portrait frames are quarter-turned into landscape without stretching."
        case .portrait:
            return "Landscape frames are quarter-turned into portrait without stretching."
        }
    }

    private var framingCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Viewer framing", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.headline)
                Picker("Viewer framing", selection: $model.framingMode) {
                    ForEach(ViewerFramingMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(framingDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var framingDescription: String {
        switch model.framingMode {
        case .fit:
            return "Shows the complete stream without cropping; mismatched screens may have black bars."
        case .fill:
            return "Fills the viewer without distortion; mismatched screens may crop the edges."
        case .stretch:
            return "Fills the viewer without cropping; mismatched screens are stretched to fit."
        }
    }

    private var buildLabel: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "?"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "?"
        return "v\(version) (\(build)) · browser port \(AppConstants.browserViewerPort)"
    }

    private var orientationDiagnostic: String? {
        UserDefaults(suiteName: AppConstants.appGroup)?
            .string(forKey: AppConstants.orientationDiagnosticKey)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func displayName(_ serviceName: String) -> String {
        serviceName.replacingOccurrences(of: "ScreenShare-", with: "Receiver ")
    }
}

private enum BrowserQRCode {
    private static let context = CIContext()

    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(
            by: CGAffineTransform(scaleX: 10, y: 10)
        ), let cgImage = context.createCGImage(output, from: output.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

private final class BroadcastPickerContainer: UIView {
    private let picker: RPSystemBroadcastPickerView
    private let onTap: () -> Void

    init(frame: CGRect, onTap: @escaping () -> Void) {
        self.onTap = onTap
        picker = RPSystemBroadcastPickerView(
            frame: CGRect(x: 0, y: 0, width: max(frame.width, 58), height: max(frame.height, 58))
        )
        super.init(frame: frame)

        picker.preferredExtension = AppConstants.broadcastBundleIdentifier
        picker.showsMicrophoneButton = false
        picker.tintColor = .clear
        addSubview(picker)

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Start screen sharing"
        DispatchQueue.main.async { [weak self] in
            self?.attachTapObserver(to: self?.picker)
        }
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        picker.frame = bounds
        picker.layoutIfNeeded()
    }

    @objc private func broadcastButtonTouched() {
        onTap()
    }

    private func attachTapObserver(to view: UIView?) {
        guard let view else { return }
        if let control = view as? UIControl {
            control.addTarget(
                self,
                action: #selector(broadcastButtonTouched),
                for: .touchDown
            )
        }
        for child in view.subviews {
            attachTapObserver(to: child)
        }
    }

}

private struct BroadcastPicker: UIViewRepresentable {
    let onTap: () -> Void

    func makeUIView(context: Context) -> BroadcastPickerContainer {
        BroadcastPickerContainer(
            frame: CGRect(x: 0, y: 0, width: 300, height: 58),
            onTap: onTap
        )
    }

    func updateUIView(_ uiView: BroadcastPickerContainer, context: Context) {}
}
