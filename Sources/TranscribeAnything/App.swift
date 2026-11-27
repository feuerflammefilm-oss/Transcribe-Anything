import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct TranscribeAnythingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup("FuFF Transcribe") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Dateien öffnen …") { openFiles(store: store) }
                    .keyboardShortcut("o")
            }
        }
    }
}

@MainActor
func openFiles(store: Store) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.prompt = "Laden"
    if panel.runModal() == .OK { store.add(urls: panel.urls) }
}
