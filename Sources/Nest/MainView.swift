import SwiftUI
import NestCore

struct MainView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var dump: DumpStore

    private var isActivity: Bool { store.selectedTab == "Activity" }
    private var active: Bool { store.ready && store.monitoring && !store.preferences.paused }
    private var status: String {
        if store.backgroundApprovalRequired { return "Background permission needed" }
        if store.backgroundServiceIssue != nil { return "Automatic sorting unavailable" }
        if store.downloadsPermissionDenied { return "Downloads access denied" }
        if store.checkingDownloadsAccess || store.requestingDownloadsAccess { return "Checking Downloads access…" }
        if store.preferences.source == nil { return "Downloads access needed" }
        if store.preferences.destination == nil { return "Choose a destination" }
        if store.preferences.paused { return "Routing paused" }
        if !store.monitoring { return "Downloads unavailable" }
        if !store.busy.isEmpty { return "Moving files…" }
        return "Watching for AirDrop files"
    }
    private var visibleHistory: [Transfer] {
        isActivity ? store.preferences.history : Array(store.preferences.history.prefix(10))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Palette.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 20) {
                if store.selectedTab == "Dump" {
                    DumpTab(store: store, dump: dump)
                } else {
                    header
                    if let issue = store.backgroundServiceIssue {
                        HStack(spacing: 12) {
                            Text(issue).font(.system(size: 12)).foregroundStyle(Palette.warning)
                            Spacer()
                            if store.backgroundApprovalRequired {
                                Button("Open System Settings") { store.openBackgroundSettings() }
                            } else {
                                Button(store.connectingToBackground ? "Connecting…" : "Retry") { store.retryBackgroundService() }
                                    .disabled(store.connectingToBackground)
                            }
                        }.buttonStyle(NestActionStyle()).padding(12)
                            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if store.backgroundServiceIssue == nil, let issue = store.downloadsAccessIssue { downloadsAccessBanner(issue) }
                    if let notice = store.notice { noticeBar(notice) }
                    if isActivity {
                        transfers
                    } else {
                        HStack(alignment: .top, spacing: 18) {
                            transfers
                            ScrollView {
                                VStack(spacing: 16) { destinationCard; startupCard }
                            }.scrollIndicators(.hidden).frame(width: 292)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    routeBar
                }
            }.padding(26).padding(.top, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Palette.canvas).foregroundStyle(Palette.ink).tint(Palette.green)
        .nestAnimation(store.preferences.paused)
        .nestAnimation(store.pending.count)
        .nestAnimation(store.ready)
        .alert("Unable to complete action", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                NestMark()
                Text("nest").font(.system(size: 25, weight: .semibold)).tracking(-1)
            }.padding(.top, 18).padding(.bottom, 24)
            navigation("Overview", icon: "tray.and.arrow.down", key: "1")
            navigation("Activity", icon: "clock.arrow.circlepath", key: "2")
            navigation("Dump", icon: "tray.full", key: "3")
            Spacer()

        }.padding(16).frame(width: 210).background(Palette.sidebar)
    }

    private func navigation(_ title: String, icon: String, key: String) -> some View {
        Button { store.selectedTab = title } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18)
                Text(title)
                Spacer(minLength: 0)
                if title == "Overview", !store.pending.isEmpty { CountBadge(count: store.pending.count) }
            }.font(.system(size: 13, weight: .medium))
                .foregroundStyle(store.selectedTab == title ? Palette.green : Palette.muted)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(store.selectedTab == title ? Palette.mint : .clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }.buttonStyle(NestQuietStyle()).help("\(title) (⌘\(key))")
            .accessibilityAddTraits(store.selectedTab == title ? .isSelected : [])
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(isActivity ? "Activity" : "Overview").font(.system(size: 30, weight: .semibold)).tracking(-0.8)
                if isActivity {
                    Text("Last 300 transfers. Undo returns unchanged files.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                } else {
                    HStack(spacing: 6) {
                        Circle().fill(active ? Palette.green : Palette.warning).frame(width: 6, height: 6)
                        Text(status).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                }
            }
            Spacer()
            primaryAction
        }.frame(minHeight: 62)
    }

    @ViewBuilder private var primaryAction: some View {
        if store.backgroundServiceIssue != nil {
            EmptyView()
        } else if store.checkingDownloadsAccess || store.requestingDownloadsAccess {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking access…").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
        } else if store.downloadsPermissionDenied {
            EmptyView()
        } else if store.preferences.source == nil || !store.monitoring {
            accessButton(primary: true)
        } else if store.preferences.destination == nil {
            Button { store.chooseDefault() } label: { Label("Choose destination", systemImage: "folder.badge.plus") }
                .buttonStyle(NestActionStyle(primary: true))
        } else {
            Button { store.togglePause() } label: {
                Label(store.preferences.paused ? "Resume routing" : "Pause routing", systemImage: store.preferences.paused ? "play.fill" : "pause.fill")
            }.buttonStyle(NestActionStyle(primary: store.preferences.paused))
        }
    }

    private func downloadsAccessBanner(_ issue: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.warning).padding(.top, 2)
            VStack(alignment: .leading, spacing: 9) {
                Text(store.downloadsPermissionDenied ? "Downloads access denied" : "Downloads unavailable")
                    .font(.system(size: 13, weight: .semibold))
                Text(issue).font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    if store.downloadsPermissionDenied {
                        Button("Open System Settings") { store.openFilesAndFoldersSettings() }.buttonStyle(NestActionStyle())
                    }
                    Button(store.requestingDownloadsAccess ? "Checking…" : "Retry access") {
                        Task { await store.requestDownloadsAccess() }
                    }.buttonStyle(NestQuietStyle()).font(.system(size: 12)).foregroundStyle(Palette.green)
                        .disabled(store.requestingDownloadsAccess || store.checkingDownloadsAccess)
                }
            }
            Spacer(minLength: 0)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.warning.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.warning.opacity(0.2)))
    }

    private func noticeBar(_ notice: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle").foregroundStyle(Palette.green)
            Text(notice).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Button { store.notice = nil } label: { Image(systemName: "xmark").padding(4) }
                .buttonStyle(NestQuietStyle()).help("Dismiss notification").accessibilityLabel("Dismiss notification")
        }.font(.system(size: 11)).padding(12).background(Palette.mint, in: RoundedRectangle(cornerRadius: 9))
    }

    private var emptyTransferMessage: String {
        if store.downloadsPermissionDenied { return "Enable Downloads access to resume routing." }
        if store.checkingDownloadsAccess { return "Connecting to Downloads…" }
        if store.preferences.paused { return "Resume routing to move incoming files." }
        if active { return "AirDrop a file to this Mac.\nIt will appear here after Nest moves it." }
        return "Complete setup to route incoming AirDrop files."
    }

    private var transfers: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(isActivity ? "Transfers" : "Recent transfers").font(.system(size: 15, weight: .semibold))
                CountBadge(count: isActivity ? visibleHistory.count : store.preferences.history.count)
                Spacer(minLength: 8)
                if isActivity {
                    Button { store.openDestinationFolder() } label: {
                        Label("Open folder", systemImage: "folder")
                    }
                    .buttonStyle(NestQuietStyle()).font(.system(size: 11)).foregroundStyle(Palette.green)
                    .disabled(store.preferences.destination == nil)
                    .help("Open the current AirDrop destination in Finder")
                }
                if !isActivity && store.preferences.history.count > 10 {
                    Button("View all") { store.selectedTab = "Activity" }
                        .buttonStyle(NestQuietStyle()).font(.system(size: 11)).foregroundStyle(Palette.green)
                }
            }
            Rectangle().fill(Palette.line).frame(height: 1)
            if visibleHistory.isEmpty && store.pending.isEmpty {
                EmptyState(icon: "arrow.down.to.line.compact",
                           title: "No transfers yet",
                           detail: emptyTransferMessage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !store.pending.isEmpty {
                            HStack {
                                Text("Pending").font(.system(size: 11, weight: .semibold))
                                CountBadge(count: store.pending.count)
                            }.foregroundStyle(Palette.muted).padding(.bottom, 6)
                            ForEach(store.pending) { file in
                                PendingRow(file: file)
                                Rectangle().fill(Palette.line).frame(height: 1)
                            }
                        }
                        ForEach(visibleHistory) { transfer in
                            HistoryRow(transfer: transfer)
                            Rectangle().fill(Palette.line).frame(height: 1)
                        }
                    }
                    // Keep row actions clear of macOS overlay scrollbars.
                    .padding(.trailing, 20)
                }.scrollIndicators(.automatic)
            }
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).nestPanel()
    }

    private var destinationCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Destination", systemImage: "folder").font(.system(size: 14, weight: .semibold))
                Text("New AirDrop files move here after the transfer settles.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                folderSummary(store.preferences.destination, empty: "Choose a destination folder")
                HStack {
                    Button(store.preferences.destination == nil ? "Choose folder" : "Change folder") { store.chooseDefault() }
                        .buttonStyle(NestActionStyle())
                    Spacer(minLength: 0)
                    if let folder = store.preferences.destination { revealButton(folder.path, help: "Show destination in Finder") }
                }
            }
        }
    }

    private func folderSummary(_ reference: FolderReference?, empty: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(reference.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? empty)
                .font(.system(size: 13, weight: .medium)).lineLimit(1)
            if let reference {
                Text(reference.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2)
                    .truncationMode(.middle).textSelection(.enabled)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.inset, in: RoundedRectangle(cornerRadius: 8))
    }

    private func accessButton(primary: Bool = false) -> some View {
        Button { Task { await store.requestDownloadsAccess() } } label: {
            HStack(spacing: 7) {
                if store.requestingDownloadsAccess { ProgressView().controlSize(.small) }
                else { Image(systemName: "folder.badge.gearshape") }
                Text(store.requestingDownloadsAccess ? "Requesting access…" : store.preferences.source == nil ? "Allow Downloads Access" : "Check access")
            }
        }.buttonStyle(NestActionStyle(primary: primary)).disabled(store.requestingDownloadsAccess)
    }

    private var routeBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle").foregroundStyle(Palette.green)
            Text("Downloads")
            Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(Palette.muted)
            Text(store.preferences.destination.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "No destination")
                .foregroundStyle(Palette.muted).lineLimit(1)
            Spacer(minLength: 12)
            Text("AirDrop: files only").foregroundStyle(Palette.muted).help("Received folders remain in Downloads.")
        }.font(.system(size: 10)).padding(.horizontal, 14).padding(.vertical, 12)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
    }

    private var startupCard: some View {
        Card {
            Toggle("Keep running in background", isOn: Binding(get: { store.keepRunningInBackground }, set: { store.setBackgroundRunning($0) }))
                .font(.system(size: 12, weight: .medium)).toggleStyle(.switch)
                .help("Keep AirDrop routing and Dump available after quitting the main app")
            Toggle("Open window at login", isOn: Binding(get: { store.loginEnabled }, set: { store.setLogin($0) }))
                .font(.system(size: 12, weight: .medium)).toggleStyle(.switch)
                .help("Open Nest automatically when you sign in to your Mac")
        }
    }

    private func revealButton(_ path: String, help: String) -> some View {
        Button { store.reveal(path) } label: { Image(systemName: "arrow.up.right.square").padding(4) }
            .buttonStyle(NestQuietStyle()).foregroundStyle(Palette.muted).help(help).accessibilityLabel(help)
    }
}
