import AppKit
import StayUpCore
import StayUpService
import SwiftUI

@main
struct StayUpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var manager = AppServices.shared.manager
    @State private var navigation = AppNavigation()
    @State private var hasPresentedInitialWindow = false
    private let presentsInitialWindow =
        !CommandLine.arguments.contains("--stay-up-background")

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(manager: manager, navigation: navigation)
        } label: {
            MenuBarLabel(
                manager: manager,
                symbol: menuBarSymbol,
                presentsInitialWindow: presentsInitialWindow,
                hasPresentedInitialWindow: $hasPresentedInitialWindow
            )
        }
        .menuBarExtraStyle(.menu)

        Window("StayUp", id: "main") {
            MainWindow(manager: manager, navigation: navigation)
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentMinSize)
    }

    private var menuBarSymbol: String {
        switch manager.state {
        case .idle, .deactivating: "moon.zzz"
        case .activating: "hourglass"
        case .active: "eye.fill"
        case .degraded: "eye.trianglebadge.exclamationmark"
        }
    }

}

private struct MenuBarLabel: View {
    let manager: SessionManager
    let symbol: String
    let presentsInitialWindow: Bool
    @Binding var hasPresentedInitialWindow: Bool

    @Environment(\.openWindow) private var openWindow
    @State private var now = Date()

    var body: some View {
        // 状態を色ではなくシンボルで表す（色だけで状態を表現しない）。
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
        }
        .task {
            guard presentsInitialWindow, !hasPresentedInitialWindow else { return }
            hasPresentedInitialWindow = true
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                now = .now
            }
        }
    }

    private var title: String {
        guard manager.settings.showRemainingInMenuBar,
              manager.isActive,
              let endsAt = manager.statusSnapshot().endsAt
        else { return "" }
        let remaining = max(0, Int(endsAt.timeIntervalSince(now).rounded()))
        return DurationParsing.formatShort(seconds: remaining)
    }
}

/// メニューバー常駐なので Dock には出さない。
/// ウィンドウを開いたときだけ通常アプリに切り替える。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 直接起動したときはメインウィンドウを見せる。
        // 最初から accessory にすると、何も起きなかったように見えてしまう。
        // ウィンドウを閉じた後は MainWindow 側でメニューバー常駐へ切り替える。
        let backgroundLaunch = CommandLine.arguments.contains("--stay-up-background")
        NSApp.setActivationPolicy(backgroundLaunch ? .accessory : .regular)
        // UI が開かれるのを待たずにサービスを立ち上げる。
        // CLI はメニューを一度も開いていない状態でも繋がる必要がある。
        Task { @MainActor in
            await AppServices.shared.start()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 終了前に必ず復元する（復元保証の層 3）
        Task { @MainActor in
            await AppServices.shared.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// アプリ全体で 1 つだけ持つサービス群。
///
/// `SessionManager` が真実の源で、UI もソケットもここを経由する。
@MainActor
final class AppServices {
    static let shared = AppServices()

    let manager = SessionManager()
    private let notifier = Notifier()
    private var socketServer: ControlSocketServer?
    private let globalHotKeys = GlobalHotKeyController()
    private var started = false

    private init() {}

    func start() async {
        guard !started else { return }
        started = true

        manager.approvalHandler = { [weak self] name, reason in
            await self?.requestApproval(clientNamed: name, reason: reason) ?? false
        }
        // 自動失効と復元失敗は、画面を見ていなくても届く必要がある（spec §8.4）
        manager.onAutoRelease = { [weak self] leases, reason in
            self?.notifier.notifyGlobalStop(leases: leases, reason: reason)
        }
        manager.onRestoreFailed = { [weak self] message in
            self?.notifier.notifyRestoreFailure(message)
        }
        // 許可ダイアログの応答を待たない。待つとソケットが開かず、
        // 利用者がダイアログを閉じるまで CLI が繋がらなくなる。
        Task { await notifier.requestAuthorization() }
        startGlobalHotKeys()
        manager.start()
        await manager.recoverOwnedOrphanedState()
        startSocket()
    }

    private func startGlobalHotKeys() {
        let failures = globalHotKeys.start { [weak self] action in
            self?.handleGlobalHotKey(action)
        }
        for action in failures {
            manager.appendWarning(
                "グローバルショートカット \(action.shortcutDescription) を登録できませんでした"
            )
        }
    }

    private func handleGlobalHotKey(_ action: GlobalHotKeyAction) {
        switch action {
        case .start(let preset):
            guard !manager.isActive else { return }
            Task {
                _ = await manager.acquire(
                    client: .interactive(trigger: .hotkey),
                    label: "ホットキー",
                    ttlSeconds: preset.seconds,
                    binding: nil
                )
            }
        case .stop:
            guard manager.isActive else { return }
            Task {
                await manager.releaseAll(requestedBy: .interactive(trigger: .hotkey))
            }
        }
    }

    private func startSocket() {
        guard manager.settings.cliEnabled else { return }
        let server = ControlSocketServer(handler: ControlRequestHandler(manager: manager))
        do {
            try server.start()
            socketServer = server
        } catch {
            manager.appendWarning("CLI ソケットを開けませんでした: \(error)")
        }
    }

    /// 未知のクライアントからの要求をユーザーに確認する（spec §12.4）。
    ///
    /// 応答が無いまま放置されると呼び出し元が待たされるので、必ずタイムアウトさせる。
    private func requestApproval(clientNamed name: String, reason: String?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "\"\(name)\" がスリープ抑止を要求しています"
        alert.informativeText = reason ?? "この要求を許可しますか？"
        alert.addButton(withTitle: "許可")
        alert.addButton(withTitle: "今回のみ")
        alert.addButton(withTitle: "拒否")
        alert.alertStyle = .informational

        // このダイアログは自分では閉じない。
        //
        // `runModal()` はメインスレッドを完全に握るため、DispatchQueue でも
        // common モードの Timer でも畳めないことを実測で確認している。
        // 自動で閉じるには非ブロッキングなシートに作り替える必要があり、0.1.0 では見送った。
        //
        // ただし SessionManager 側は 30 秒で拒否を確定させるので、
        // 後から「許可」が押されてもリースは作られない（spec §10）。
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            manager.approveClientPermanently(name)
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func shutdown() async {
        globalHotKeys.stop()
        socketServer?.stop()
        socketServer = nil
        await manager.shutdown()
    }
}
