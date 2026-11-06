import AppKit
import SwiftUI
import NestCore
import Carbon

@MainActor
final class NestAppDelegate: NSObject, NSApplicationDelegate {
    private var dump: DumpStore?
    private weak var store: AppStore?
    private var localStatus: NestStatusItem?
    private var quittingAll = false
    private let replyToTermination: @MainActor (Bool) -> Void
    private var openMainWindow: (() -> Void)?

    override convenience init() {
        self.init(dump: nil)
    }

    init(dump: DumpStore?, store: AppStore? = nil, replyToTermination: @escaping @MainActor (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }) {
        self.dump = dump
        self.store = store
        self.replyToTermination = replyToTermination
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(showMainWindow), name: .nestOpenMainWindow, object: nil)
    }

    private weak var client: BackgroundClient?
    func install(store: AppStore, dump: DumpStore, openNest: @escaping () -> Void) {
        self.dump = dump
        self.store = store
        openMainWindow = openNest
        if store.usesBackgroundService {
            BackgroundDiagnostics.record("mode", message: "Separate helper; main window is an XPC client")
            store.connectToBackgroundService()
            client = store.backgroundClient
        } else {
            guard localStatus == nil else { return }
            BackgroundDiagnostics.record("mode", message: "Menu bar engine; locally signed build")
            localStatus = NestStatusItem(store: store, dump: dump, openNest: { [weak self] in
                self?.showMainWindow()
            }, quitNest: { [weak self] in
                self?.quittingAll = true
                NSApp.terminate(nil)
            })
            Task { await store.requestInitialDownloadsAccessIfNeeded() }
            Task { await SystemBackgroundRegistration().retireIdleService() }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }
    @objc private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        openMainWindow?()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        store?.keepRunningInBackground == false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let localStore = store?.usesBackgroundService == false ? store : nil
        let reason = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: kAEQuitReason)?.enumCodeValue
        let systemQuit = reason.map { [kAEQuitAll, kAEShutDown, kAERestart, kAEReallyLogOut, kAELogOut].contains($0) } ?? false
        if let localStore, localStore.keepRunningInBackground, !quittingAll, !systemQuit {
            for window in sender.windows where window.level == .normal { window.orderOut(nil) }
            sender.setActivationPolicy(.accessory)
            return .terminateCancel
        }
        localStore?.acceptingTransfers = false
        localStore?.stopWatching()
        dump?.acceptingTransfers = false
        guard dump?.isTransferring == true || localStore?.busy.isEmpty == false else { return .terminateNow }
        Task {
            while dump?.isTransferring == true || localStore?.busy.isEmpty == false {
                try? await Task.sleep(for: .milliseconds(100))
            }
            localStore?.save()
            replyToTermination(true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        DiagnosticLog.shared.finishSession()
        client?.stop()
        localStatus?.stop()
        dump?.stopWatching()
    }

}

@MainActor
final class NestStatusItem: NSObject, NSPopoverDelegate {
    private let item: NSStatusItem
    private let popover = NSPopover()
    private let store: AppStore
    private let dump: DumpStore
    var openNest: () -> Void
    private let quitNest: () -> Void

    init(store: AppStore, dump: DumpStore, openNest: @escaping () -> Void, quitNest: @escaping () -> Void) {
        self.store = store; self.dump = dump; self.openNest = openNest; self.quitNest = quitNest
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(openDumpPanel), name: .nestOpenDump, object: nil)
        item.autosaveName = "NestDump"
        // Dump stays available while the user selects files in Finder or another app.
        popover.behavior = .applicationDefined
        popover.delegate = self
        popover.contentSize = NSSize(width: 420, height: 560)
        let content = DumpPopover(store: store, dump: dump, quitNest: quitNest,
            close: { [weak self] in self?.popover.performClose(nil) },
            openNest: { [weak self] in self?.popover.performClose(nil); self?.openNest() },
            transferOut: { [weak self] urls, mode in self?.transferOut(urls, mode: mode) })
        let controller = NSViewController()
        controller.view = DumpHostingView(rootView: content, dump: dump)
        popover.contentViewController = controller
        if let button = item.button {
            button.image = NestBrand.menuBarLogo
            button.toolTip = "Nest Dump: click to open, or drop files here"
            button.setAccessibilityLabel("Nest Dump")
            button.target = self
            button.action = #selector(togglePopover)
            let drop = FileDropView(frame: button.bounds)
            drop.autoresizingMask = [.width, .height]
            drop.showBorder = false
            drop.setAccessibilityElement(false)
            drop.canAccept = { [weak dump] in dump?.canAcceptTransfers == true }
            drop.receive = { [weak self] urls in
                self?.dump.addFiles(urls)
                self?.showPopover()
            }
            drop.clicked = { [weak self] event in
                if event.type == .rightMouseDown { self?.showMenu(event) }
                else { self?.togglePopover() }
            }
            button.addSubview(drop)
        }
    }
    @objc private func openDumpPanel() { showPopover() }
    @objc private func togglePopover() { if popover.isShown { popover.performClose(nil) } else { showPopover() } }
    private func showPopover() {
        guard !popover.isShown, let button = item.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let window = popover.contentViewController?.view.window {
            window.hidesOnDeactivate = false
            window.level = .floating
            window.makeKey()
        }
    }
    private func transferOut(_ urls: [URL], mode: DumpTransferMode) {
        popover.performClose(nil)
        dump.transferOut(urls, mode: mode)
        showPopover()
    }
    private func showMenu(_ event: NSEvent) {
        guard let button = item.button else { return }
        popover.performClose(nil)
        let menu = NSMenu()
        func action(_ title: String, _ selector: Selector) {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            entry.target = self; menu.addItem(entry)
        }
        action("Open Dump in Finder", #selector(openDump))
        action("Open Nest", #selector(openMain))
        action("Export Diagnostics…", #selector(exportDiagnostics))
        menu.addItem(.separator())
        action(store.preferences.paused ? "Resume AirDrop routing" : "Pause AirDrop routing", #selector(pauseRouting))
        menu.addItem(.separator())
        action("Quit Nest", #selector(quit))
        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }
    @objc private func exportDiagnostics() { DiagnosticsExport.show() }
    @objc private func openDump() { dump.openFolder() }
    @objc private func openMain() { openNest() }
    @objc private func pauseRouting() { store.togglePause() }
    @objc private func quit() { quitNest() }
    func popoverDidClose(_ notification: Notification) { dump.isDropTargeted = false }
    func stop() { dump.stopWatching(); store.stopWatching() }
}

struct NestRootView: View {
    let delegate: NestAppDelegate
    let store: AppStore
    let dump: DumpStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        MainView().environmentObject(store).environmentObject(dump)
            .onAppear {
                delegate.install(store: store, dump: dump) {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

extension Notification.Name {
    static let nestOpenMainWindow = Notification.Name("NestOpenMainWindow")
    static let nestOpenDump = Notification.Name("NestOpenDump")
}
