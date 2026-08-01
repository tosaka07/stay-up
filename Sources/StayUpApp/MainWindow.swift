import AppKit
import StayUpCore
import StayUpService
import SwiftUI

/// メインウィンドウの情報設計。
///
/// 日常的に見る状態と、必要なときだけ触る管理機能をサイドバーで分離する。
/// NavigationSplitView と標準 toolbar を使うことで、macOS 26 の Liquid Glass を
/// システムに任せる。
@MainActor
@Observable
final class AppNavigation {
    var selection = MainDestination.overview
}

struct MainWindow: View {
    @Bindable var manager: SessionManager
    @Bindable var navigation: AppNavigation

    @State private var selectedLeaseIDs: Set<LeaseID> = []
    @State private var helper = HelperClient()
    @State private var helperStatus: HelperStatus = .notRegistered
    @State private var isShowingHelperSetup = false

    var body: some View {
        NavigationSplitView {
            Sidebar(
                selection: $navigation.selection,
                leaseCount: manager.leases.count,
                warningCount: manager.warnings.count
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 250)
        } detail: {
            detail
                .navigationTitle(navigation.selection.title)
                .toolbar { windowToolbar }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 820, minHeight: 600)
        .task { refreshHelperStatus() }
        .sheet(isPresented: $isShowingHelperSetup, onDismiss: refreshHelperStatus) {
            HelperSetupView(helper: helper)
        }
        .onDisappear {
            // ウィンドウを閉じたらメニューバー常駐に戻る。
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.selection {
        case .overview:
            OverviewView(
                manager: manager,
                helperStatus: helperStatus,
                onConfigureHelper: { isShowingHelperSetup = true }
            )
        case .sessions:
            SessionsView(manager: manager, selection: $selectedLeaseIDs)
        case .history:
            HistoryView(manager: manager)
        case .integrations:
            IntegrationsView(manager: manager)
        case .settings:
            SettingsView(manager: manager)
        case .diagnostics:
            DiagnosticsView(
                manager: manager,
                helperStatus: helperStatus,
                onConfigureHelper: { isShowingHelperSetup = true },
                onRefreshHelper: refreshHelperStatus
            )
        }
    }

    @ToolbarContentBuilder
    private var windowToolbar: some ToolbarContent {
        if navigation.selection == .sessions, !selectedLeaseIDs.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    releaseSelectedLeases()
                } label: {
                    Label("選択したセッションを解除", systemImage: "trash")
                }
                .help("選択したセッションを解除")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItem(placement: .primaryAction) {
            if manager.isActive {
                Button(role: .destructive) {
                    releaseAll()
                } label: {
                    Label("すべて解除", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut("0", modifiers: .stayUpGlobalHotKey)
                .help("すべてのセッションを解除")
            } else {
                Menu {
                    durationButton(.thirtyMinutes)
                    durationButton(.oneHour)
                    durationButton(.twoHours)
                    Divider()
                    durationButton(.unlimited)
                } label: {
                    Image(systemName: "play.fill")
                } primaryAction: {
                    acquire(ttl: manager.settings.defaultDurationSeconds)
                }
                .accessibilityLabel(defaultStartTitle)
                .help("\(defaultStartTitle)。矢印から別の期間を選べます")
            }
        }
    }

    private var defaultStartTitle: String {
        let seconds = manager.settings.defaultDurationSeconds
        if let preset = StartDurationPreset.matching(seconds: seconds) {
            return preset.actionTitle
        }
        guard let seconds else { return StartDurationPreset.unlimited.actionTitle }
        return "\(DurationParsing.format(seconds: seconds))で開始"
    }

    private func durationButton(_ preset: StartDurationPreset) -> some View {
        Button {
            acquire(ttl: preset.seconds)
        } label: {
            if manager.settings.defaultDurationSeconds == preset.seconds {
                Label(preset.actionTitle, systemImage: "checkmark")
            } else {
                Text(preset.actionTitle)
            }
        }
        .keyboardShortcut(preset.keyEquivalent, modifiers: .stayUpGlobalHotKey)
    }

    private func releaseAll() {
        Task {
            await manager.releaseAll(requestedBy: .interactive(trigger: .window))
        }
    }

    private func acquire(ttl: Int?) {
        Task {
            _ = await manager.acquire(
                client: .interactive(trigger: .window),
                label: "手動",
                ttlSeconds: ttl,
                binding: nil
            )
        }
    }

    private func releaseSelectedLeases() {
        let ids = selectedLeaseIDs
        selectedLeaseIDs.removeAll()
        Task {
            for id in ids {
                _ = await manager.release(
                    id: id,
                    requestedBy: .interactive(trigger: .window)
                )
            }
        }
    }

    private func refreshHelperStatus() {
        helperStatus = helper.status
    }
}

enum MainDestination: String, CaseIterable, Identifiable {
    case overview
    case sessions
    case history
    case integrations
    case settings
    case diagnostics

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "概要"
        case .sessions: "セッション"
        case .history: "履歴"
        case .integrations: "連携"
        case .settings: "設定"
        case .diagnostics: "診断"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "circle.grid.2x2"
        case .sessions: "bolt.horizontal.circle"
        case .history: "clock.arrow.circlepath"
        case .integrations: "point.3.connected.trianglepath.dotted"
        case .settings: "gearshape"
        case .diagnostics: "stethoscope"
        }
    }
}

private struct Sidebar: View {
    @Binding var selection: MainDestination
    let leaseCount: Int
    let warningCount: Int

    var body: some View {
        List(selection: $selection) {
            sidebarRow(.overview)

            Section("アクティビティ") {
                sidebarRow(.sessions, badge: leaseCount)
                sidebarRow(.history)
            }

            Section("管理") {
                sidebarRow(.integrations)
                sidebarRow(.settings)
            }

            Section {
                sidebarRow(.diagnostics, badge: warningCount)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("StayUp")
    }

    private func sidebarRow(_ destination: MainDestination, badge: Int = 0) -> some View {
        Label(destination.title, systemImage: destination.symbol)
            .badge(badge)
            .tag(destination)
    }
}
