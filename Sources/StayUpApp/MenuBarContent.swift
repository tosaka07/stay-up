import AppKit
import StayUpCore
import StayUpService
import SwiftUI

/// メニューバーはネイティブメニューとして構成する。
///
/// 日常操作と状態確認に絞り、情報量の多い画面はメインウィンドウへ渡す。
/// セッションごとの詳細と操作はサブメニューに置く。
struct MenuBarContent: View {
    @Bindable var manager: SessionManager
    @Bindable var navigation: AppNavigation

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openMainWindow()
        } label: {
            Label("StayUpを開く", systemImage: "macwindow")
        }
        .keyboardShortcut("0", modifiers: .command)

        Divider()

        Section("状態") {
            statusItem

            if let powerTitle {
                Button {} label: {
                    Label(powerTitle, systemImage: powerSymbol)
                }
                .disabled(true)
            }

            if !manager.warnings.isEmpty {
                warningMenu
            }
        }

        if manager.isActive {
            activeSessions
        } else {
            startMenu
        }

        Divider()

        Button {
            openMainWindow(at: .diagnostics)
        } label: {
            Label("診断…", systemImage: "stethoscope")
        }

        Button {
            openMainWindow(at: .settings)
        } label: {
            Label("設定…", systemImage: "gearshape")
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button {
            NSApp.terminate(nil)
        } label: {
            Label("StayUpを終了", systemImage: "xmark")
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private var statusItem: some View {
        Button {} label: {
            Label(statusTitle, systemImage: statusSymbol)
        }
        .disabled(true)
    }

    private var warningMenu: some View {
        Menu {
            ForEach(manager.warnings, id: \.self) { warning in
                Button(warning) {}
                    .disabled(true)
            }
        } label: {
            Label(
                "\(manager.warnings.count)件の警告",
                systemImage: "exclamationmark.triangle.fill"
            )
        }
    }

    private var startMenu: some View {
        Section("スリープ") {
            Menu {
                startButton(.thirtyMinutes)
                startButton(.oneHour)
                startButton(.twoHours)
                Divider()
                startButton(.unlimited)
            } label: {
                Label("StayUpを開始", systemImage: "play.fill")
            }
        }
    }

    private var activeSessions: some View {
        Group {
            Section("実行中のセッション") {
                ForEach(manager.leases) { lease in
                    sessionMenu(lease)
                }
            }

            Section {
                Button(role: .destructive) {
                    Task {
                        await manager.releaseAll(
                            requestedBy: .interactive(trigger: .menuBar)
                        )
                    }
                } label: {
                    Label("すべて解除", systemImage: "stop.fill")
                }
                .keyboardShortcut("0", modifiers: .stayUpGlobalHotKey)
            }
        }
    }

    private func startButton(_ preset: StartDurationPreset) -> some View {
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

    private func sessionMenu(_ lease: Lease) -> some View {
        Menu {
            Button("開始：\(lease.acquiredAt.formatted(date: .omitted, time: .shortened))") {}
                .disabled(true)

            Button(remainingText(for: lease)) {}
                .disabled(true)

            if lease.label != lease.client.name, !lease.client.name.isEmpty {
                Button("要求元：\(lease.client.name)") {}
                    .disabled(true)
            }

            if let binding = lease.binding {
                Button("連動：\(binding.displayText)") {}
                    .disabled(true)
            }

            if lease.client.isInteractive {
                Divider()

                Menu {
                    extendButton("30分", lease: lease, seconds: 30 * 60)
                    extendButton("1時間", lease: lease, seconds: 60 * 60)
                    extendButton("2時間", lease: lease, seconds: 2 * 60 * 60)
                } label: {
                    Label("延長", systemImage: "clock.badge.plus")
                }
            }

            Divider()

            Button(role: .destructive) {
                Task {
                    _ = await manager.release(
                        id: lease.id,
                        requestedBy: .interactive(trigger: .menuBar)
                    )
                }
            } label: {
                Label("このセッションを解除", systemImage: "stop.fill")
            }
        } label: {
            Label(sessionTitle(for: lease), systemImage: sessionSymbol(for: lease))
        }
    }

    private func extendButton(
        _ label: String,
        lease: Lease,
        seconds: Int
    ) -> some View {
        Button(label) {
            manager.extend(id: lease.id, bySeconds: seconds)
        }
    }

    private var statusTitle: String {
        switch manager.state {
        case .idle:
            "通常どおりスリープ"
        case .activating:
            "スリープ抑止を開始中"
        case .active:
            "ふたを閉じても実行中"
        case .deactivating:
            "スリープ設定を復元中"
        case .degraded:
            "アイドルスリープのみ抑止"
        }
    }

    private var statusSymbol: String {
        switch manager.state {
        case .idle, .deactivating:
            "moon.zzz"
        case .activating:
            "hourglass"
        case .active:
            "bolt.horizontal.fill"
        case .degraded:
            "exclamationmark.triangle.fill"
        }
    }

    private var powerTitle: String? {
        switch (manager.battery.source, manager.battery.percent) {
        case (.ac, let percent?):
            "電源アダプタ接続（\(percent)%）"
        case (.ac, nil):
            "電源アダプタ接続"
        case (.battery, let percent?):
            "バッテリー \(percent)%"
        case (.battery, nil):
            "バッテリー駆動"
        case (.unknown, let percent?):
            "電源状態不明（\(percent)%）"
        case (.unknown, nil):
            nil
        }
    }

    private var powerSymbol: String {
        manager.battery.source == .ac ? "powerplug.fill" : "battery.75percent"
    }

    private func sessionTitle(for lease: Lease) -> String {
        lease.label.isEmpty ? lease.client.name : lease.label
    }

    private func sessionSymbol(for lease: Lease) -> String {
        lease.client.isInteractive ? "person.fill" : "terminal.fill"
    }

    private func remainingText(for lease: Lease) -> String {
        guard let seconds = lease.remainingSeconds(at: Date()) else {
            return "残り：無期限"
        }
        return "残り：\(DurationParsing.formatShort(seconds: seconds))"
    }

    private func acquire(ttl: Int?) {
        Task {
            _ = await manager.acquire(
                client: .interactive(trigger: .menuBar),
                label: "手動",
                ttlSeconds: ttl,
                binding: nil
            )
        }
    }

    private func openMainWindow(at destination: MainDestination? = nil) {
        if let destination {
            navigation.selection = destination
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}
