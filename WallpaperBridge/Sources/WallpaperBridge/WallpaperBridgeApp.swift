import AppKit
import SwiftUI

@main
struct WallpaperBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        // Main window: opens at launch and when you click the Dock icon.
        Window("Wallpaper Bridge", id: "main") {
            ContentView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)

        // The same controls, also available from the menu bar.
        MenuBarExtra("Wallpaper Bridge", systemImage: "photo.on.rectangle.angled") {
            ContentView()
                .environmentObject(state)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Normal app with a Dock icon, so it's easy to find.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppState.shared.restoreLastWallpaper()
    }

    // Closing the window keeps the app (and the wallpaper) running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
