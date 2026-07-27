import SwiftUI

@main
struct ScreenShareReceiverApp: App {
    @UIApplicationDelegateAdaptor(ReceiverAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ReceiverRootView()
        }
    }
}

