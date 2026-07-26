import AVKit
import SwiftUI
import UIKit

struct ReceiverRootView: View {
    @StateObject private var session = ViewerSession()
    @State private var controlsVisible = false
    @State private var copied = false
    @State private var showRotateConfirmation = false
    @State private var hideControlsWorkItem: DispatchWorkItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(view: session.renderer)
                .ignoresSafeArea()

            if !session.hasPicture {
                waitingView
                    .transition(.opacity)
            } else if controlsVisible {
                controls
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard session.hasPicture else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                controlsVisible.toggle()
            }
            if controlsVisible { scheduleControlsHide() }
        }
        .statusBar(hidden: true)
        .screenChromeHidden()
        .preferredColorScheme(.dark)
        .alert("Generate a new pairing code?", isPresented: $showRotateConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Generate", role: .destructive) {
                session.rotatePairingCode()
            }
        } message: {
            Text("The sender will need the new code. The current connection will close.")
        }
    }

    private var waitingView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "rectangle.inset.filled.and.person.filled")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(Color.cyan)
            VStack(spacing: 7) {
                Text("Screen Share")
                    .font(.largeTitle.bold())
                Text(session.statusText)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                Text("PAIRING CODE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(session.identity.pairingCode)
                    .font(.system(size: 23, weight: .bold, design: .monospaced))
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
                Button {
                    UIPasteboard.general.string = session.identity.pairingCode
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .tint(.cyan)
            }
            .padding(22)
            .frame(maxWidth: 440)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            VStack(spacing: 7) {
                Text("On the jailbroken iPhone")
                    .font(.headline)
                Text("Open Screen Share Sender, select this receiver, enter the code, save, then tap the iOS broadcast button.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 420)

            Spacer()
            Button("Generate new code") {
                showRotateConfirmation = true
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 22)
        }
        .padding(.horizontal, 24)
        .background(
            ZStack {
                Color.black
                RadialGradient(
                    colors: [Color.cyan.opacity(0.16), .clear],
                    center: .top,
                    startRadius: 10,
                    endRadius: 500
                )
            }
            .ignoresSafeArea()
        )
    }

    private var controls: some View {
        VStack {
            HStack {
                Label(session.statusText, systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                Spacer()
                Button {
                    session.pictureInPicture.toggle()
                } label: {
                    Image(systemName: session.pictureInPicture.isActive ? "pip.exit" : "pip.enter")
                        .font(.title3.weight(.semibold))
                        .frame(width: 42, height: 42)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(!session.pictureInPicture.isPossible)
                .opacity(session.pictureInPicture.isPossible ? 1 : 0.45)
            }
            .padding()
            Spacer()
        }
    }

    private func scheduleControlsHide() {
        hideControlsWorkItem?.cancel()
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.2)) {
                controlsVisible = false
            }
        }
        hideControlsWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
}

private struct VideoSurface: UIViewRepresentable {
    let view: VideoRendererView

    func makeUIView(context: Context) -> VideoRendererView {
        view
    }

    func updateUIView(_ uiView: VideoRendererView, context: Context) {}
}

private extension View {
    @ViewBuilder
    func screenChromeHidden() -> some View {
        if #available(iOS 16.0, *) {
            persistentSystemOverlays(.hidden)
        } else {
            self
        }
    }
}
