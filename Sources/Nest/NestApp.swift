import SwiftUI
import AppKit

public enum NestEntry {
    @MainActor public static func main() {
        Diagnostics.start()
        if CommandLine.arguments.contains("--nest-check-background") {
            let started = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in
                let separate = NestBackground.usesSeparateService
                let store = AppStore(remote: separate)
                let client = separate ? BackgroundClient(store: store) : nil
                if let client { await client.send(.snapshot) }
                else {
                    await store.requestInitialDownloadsAccessIfNeeded()
                    while store.checkingDownloadsAccess { try? await Task.sleep(for: .milliseconds(10)) }
                }
                let issue = separate ? store.backgroundServiceIssue : (store.downloadsAccessIssue ?? store.error)
                let result: [String: Any] = [
                    "mode": separate ? "service" : "menu bar",
                    "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
                    "connected": issue == nil,
                    "monitoring": store.monitoring,
                    "issue": issue ?? ""
                ]
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
                   let output = String(data: data, encoding: .utf8) { print(output) }
                let success = issue == nil
                if CommandLine.arguments.contains("--stop-after-check"), success { await client?.send(.quitAll) }
                client?.stop()
                store.stopWatching()
                if !separate { await SystemBackgroundRegistration().retireIdleService() }
                DiagnosticLog.shared.finishSession()
                exit(success ? 0 : 1)
            }
            RunLoop.main.run()
        } else if NestBackground.isWorker {
            guard NestBackground.usesSeparateService else { DiagnosticLog.shared.finishSession(); return }
            let app = NSApplication.shared
            let delegate = BackgroundApplicationDelegate()
            app.setActivationPolicy(.accessory)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        } else {
            NestApp.main()
        }
    }
}

struct NestApp: App {
    @NSApplicationDelegateAdaptor(NestAppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore(remote: NestBackground.usesSeparateService)
    @StateObject private var dump = DumpStore()
    var body: some Scene {
        Window("Nest", id: "main") {
            NestRootView(delegate: appDelegate, store: store, dump: dump)
                .preferredColorScheme(.light)
                .frame(minWidth: 1000, minHeight: 660)
        }
        .defaultSize(width: 1180, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            NestCommands(store: store)
        }
    }
}

struct NestCommands: Commands {
    @ObservedObject var store: AppStore
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {}
        CommandGroup(replacing: .help) {
            Button("Export Diagnostics…") { DiagnosticsExport.show() }
        }
        CommandMenu("Navigate") {
            Button("Overview") { navigate("Overview") }.keyboardShortcut("1", modifiers: .command)
            Button("Activity") { navigate("Activity") }.keyboardShortcut("2", modifiers: .command)
            Button("Dump tab") { navigate("Dump") }.keyboardShortcut("3", modifiers: .command)
            Button("Menu bar Dump") {
                if store.usesBackgroundService { store.sendToBackground(.openDump) }
                else { NotificationCenter.default.post(name: .nestOpenDump, object: nil) }
            }.keyboardShortcut("d", modifiers: .command)
        }
    }
    private func navigate(_ tab: String) {
        store.selectedTab = tab
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
