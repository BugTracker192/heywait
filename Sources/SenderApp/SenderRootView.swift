import Combine
import ReplayKit
import SwiftUI
import UIKit

final class SenderViewModel: ObservableObject {
    @Published var selectedServiceName: String
    @Published var pairingCode: String
    @Published var quality: StreamQuality
    @Published private(set) var didSave = false

    let discovery = ReceiverDiscovery()
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let saved = SenderConfigurationStore.shared.load()
        selectedServiceName = saved.receiverServiceName
        pairingCode = PairingSecret.format(saved.pairingCode)
        quality = saved.quality

        discovery.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var configuration: SenderConfiguration {
        SenderConfiguration(
            receiverServiceName: selectedServiceName,
            pairingCode: pairingCode,
            quality: quality
        )
    }

    var isReady: Bool { configuration.isReady }

    func select(_ receiver: DiscoveredReceiver) {
        selectedServiceName = receiver.name
        didSave = false
    }

    func save() {
        guard isReady else { return }
        pairingCode = PairingSecret.format(pairingCode)
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
                        receiverCard
                        pairingCard
                        qualityCard
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
        .onAppear { model.discovery.start() }
        .onDisappear { model.discovery.stop() }
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
            }
        }
    }

    private var startCard: some View {
        card {
            VStack(spacing: 14) {
                Button {
                    model.save()
                } label: {
                    Label(model.didSave ? "Receiver saved" : "Save receiver", systemImage: model.didSave ? "checkmark" : "link")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(!model.isReady)

                Divider()

                HStack(spacing: 16) {
                    BroadcastPicker()
                        .frame(width: 58, height: 58)
                        .background(Color.cyan.opacity(0.12), in: Circle())
                        .opacity(model.didSave || SenderConfigurationStore.shared.load().isReady ? 1 : 0.35)
                        .allowsHitTesting(model.didSave || SenderConfigurationStore.shared.load().isReady)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Start sharing")
                            .font(.headline)
                        Text(
                            model.didSave || SenderConfigurationStore.shared.load().isReady
                                ? "Tap the broadcast button, then confirm once in the iOS sheet."
                                : "Choose and save a receiver to enable the broadcast button."
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    private var privacyNote: some View {
        Label(
            "Screen Share never uses a cloud relay. iOS displays its standard capture indicator while your screen is being shared.",
            systemImage: "hand.raised.fill"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
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

private struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: .zero)
        picker.preferredExtension = AppConstants.broadcastBundleIdentifier
        picker.showsMicrophoneButton = false
        picker.tintColor = .cyan
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
